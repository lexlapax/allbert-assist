defmodule AllbertAssistWeb.PackReadiness do
  @moduledoc """
  Web-side observer for the current acknowledged Pack readiness epoch.

  This process is deliberately an observer, not a Pack subscriber or an authority
  boundary.  It admits an HTTP/socket request only after it has monitored the
  barrier returned by the bounded kernel status read; every later effect boundary
  still validates the carried epoch.
  """

  use GenServer

  @observer_timeout 150
  @readiness_timeout 100
  @retry_ms 100
  @disconnect_topic "allbert_pack_readiness"

  @type epoch :: %{barrier_pid: pid(), snapshot_digest: String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec admit() :: {:ok, epoch()} | {:error, :product_not_ready}
  def admit, do: call(:admit, {:error, :product_not_ready})

  @spec validate(term()) :: :ok | {:error, :product_not_ready | :stale_epoch}
  def validate(epoch), do: call({:validate, epoch}, {:error, :product_not_ready})

  @doc false
  @spec validate_conn(Plug.Conn.t()) :: :ok | {:error, :product_not_ready | :stale_epoch}
  def validate_conn(conn), do: validate(conn.private[:allbert_pack_epoch])

  @doc false
  @spec disconnect() :: :ok
  def disconnect do
    Phoenix.Channel.Server.broadcast(
      AllbertAssistWeb.PubSub,
      @disconnect_topic,
      "disconnect",
      %{}
    )
  rescue
    _ -> :ok
  end

  @doc false
  @spec live_session(Plug.Conn.t()) :: map()
  def live_session(conn) do
    case conn.private[:allbert_pack_epoch] do
      %{barrier_pid: barrier_pid, snapshot_digest: digest}
      when is_pid(barrier_pid) and is_binary(digest) ->
        %{"allbert_pack_epoch" => %{barrier_pid: barrier_pid, snapshot_digest: digest}}

      _other ->
        %{}
    end
  end

  @doc false
  def on_mount(:live_session, _params, session, socket) do
    epoch =
      if Phoenix.LiveView.connected?(socket) do
        Phoenix.LiveView.get_connect_info(socket, :allbert_pack_epoch)
      else
        Map.get(session, "allbert_pack_epoch")
      end

    case validate(epoch) do
      :ok ->
        socket =
          socket
          |> Phoenix.Component.assign(:allbert_pack_epoch, epoch)
          |> attach_lifecycle_validation()

        {:cont, socket}

      {:error, _reason} ->
        disconnect()
        {:halt, Phoenix.LiveView.redirect(socket, to: "/health")}
    end
  end

  @impl true
  def init(opts) do
    readiness = Keyword.get(opts, :readiness, AllbertAssist.Pack.Readiness)

    # Product admission and the signal bridge deliberately have independent
    # lifecycles. A bridge is notification plumbing, never a condition of Pack
    # admission: HTTP and transports may continue during its bounded reopen.
    state = %{
      admission: :closed,
      bridge: :absent,
      readiness: readiness,
      bridge_supervisor:
        Keyword.get(opts, :bridge_supervisor, AllbertAssistWeb.SignalBridgeSupervisor),
      bridge_open_fun:
        Keyword.get(opts, :bridge_open_fun, &AllbertAssistWeb.SignalBridgeSupervisor.open/2),
      retry_ref: nil
    }

    # An observer can restart after a missed loss/replacement notification.
    # Close existing clients before it considers the first sampled epoch.
    disconnect()
    send(self(), :probe)
    {:ok, state}
  end

  @impl true
  def handle_call(:admit, _from, state) do
    {reply, state} = refresh_admission(state)
    {:reply, reply, state}
  end

  def handle_call({:validate, epoch}, _from, state) do
    {admission, state} = refresh_admission(state)

    reply =
      case admission do
        {:ok, _current_epoch} -> validation_reply(epoch, state.admission)
        {:error, :product_not_ready} -> {:error, :product_not_ready}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:probe, state) do
    state = %{state | retry_ref: nil}

    case ready_epoch(state.readiness) do
      {:ok, epoch} ->
        {:noreply, epoch |> adopt_or_keep(state) |> ensure_bridge()}

      {:error, _reason} ->
        {:noreply, close_and_retry(state)}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{admission: %{barrier_monitor_ref: ref, barrier_pid: pid}} = state
      ) do
    {:noreply, close_and_retry(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{bridge: {:open, pid, ref, _epoch}} = state
      ) do
    # Losing notifications reloads mounted clients, but must not close the
    # independently monitored Pack epoch.
    disconnect()
    {:noreply, state |> Map.put(:bridge, :absent) |> schedule_probe()}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{bridge: {:retiring, pid, ref}} = state
      ) do
    {:noreply, schedule_probe(%{state | bridge: :absent})}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp call(message, fallback) do
    try do
      GenServer.call(__MODULE__, message, @observer_timeout)
    catch
      :exit, _reason -> fallback
    end
  end

  defp ready_epoch(readiness) do
    try do
      case readiness.status(timeout: @readiness_timeout) do
        {:ok, %{phase: :ready, barrier_pid: barrier_pid, snapshot_digest: digest}}
        when is_pid(barrier_pid) and is_binary(digest) ->
          {:ok, %{barrier_pid: barrier_pid, snapshot_digest: digest}}

        _other ->
          {:error, :not_ready}
      end
    rescue
      UndefinedFunctionError -> {:error, :unavailable}
    catch
      :exit, _reason -> {:error, :unavailable}
    end
  end

  # A stored observation never grants a later request admission. The fresh read
  # closes the observer on any phase or epoch change; the retry probe may then
  # adopt the replacement epoch for a subsequent request.
  defp refresh_admission(state) do
    case ready_epoch(state.readiness) do
      {:ok, epoch} ->
        case state.admission do
          %{barrier_pid: pid, snapshot_digest: digest}
          when pid == epoch.barrier_pid and digest == epoch.snapshot_digest ->
            {admission_reply(state.admission), ensure_bridge(state)}

          :closed ->
            state = adopt_or_keep(epoch, state)
            {admission_reply(state.admission), ensure_bridge(state)}

          _different_epoch ->
            {{:error, :product_not_ready}, close_and_retry(state)}
        end

      {:error, _reason} ->
        {{:error, :product_not_ready}, close_and_retry(state)}
    end
  end

  defp adopt_or_keep(epoch, %{admission: %{barrier_pid: pid, snapshot_digest: digest}} = state)
       when pid == epoch.barrier_pid and digest == epoch.snapshot_digest,
       do: state

  defp adopt_or_keep(_epoch, %{bridge: {:retiring, _pid, _ref}} = state), do: state

  defp adopt_or_keep(epoch, state) do
    state = close_admission(state, broadcast?: state.admission != :closed)

    case state.bridge do
      {:retiring, _pid, _ref} ->
        schedule_probe(state)

      _not_retiring ->
        barrier_monitor_ref = Process.monitor(epoch.barrier_pid)

        if Process.alive?(epoch.barrier_pid) do
          %{state | admission: Map.put(epoch, :barrier_monitor_ref, barrier_monitor_ref)}
        else
          Process.demonitor(barrier_monitor_ref, [:flush])
          close_and_retry(state)
        end
    end
  end

  defp close_and_retry(state) do
    state = close_admission(state, broadcast?: state.admission != :closed)
    schedule_probe(state)
  end

  defp schedule_probe(%{retry_ref: retry_ref} = state) when not is_nil(retry_ref), do: state

  defp schedule_probe(state) do
    %{state | retry_ref: Process.send_after(self(), :probe, @retry_ms)}
  end

  defp close_admission(%{admission: :closed} = state, _opts), do: state

  defp close_admission(
         %{admission: %{barrier_monitor_ref: barrier_ref}} = state,
         opts
       ) do
    Process.demonitor(barrier_ref, [:flush])
    if Keyword.get(opts, :broadcast?, false), do: disconnect()
    %{state | admission: :closed} |> retire_bridge()
  end

  # A bridge can be unavailable or crash without invalidating the ready Pack
  # epoch. Reopen attempts share the observer's bounded 100-ms cadence.
  defp ensure_bridge(%{admission: :closed} = state), do: state
  defp ensure_bridge(%{bridge: {:open, _pid, _ref, _epoch}} = state), do: state
  defp ensure_bridge(%{bridge: {:retiring, _pid, _ref}} = state), do: state

  defp ensure_bridge(%{admission: epoch, bridge: :absent} = state) do
    case state.bridge_open_fun.(epoch, state.bridge_supervisor) do
      {:ok, bridge_pid} when is_pid(bridge_pid) ->
        bridge_ref = Process.monitor(bridge_pid)
        # A successful bridge subscription can follow a reconnect during its
        # gap; reload it so it sees durable state under the new subscriber.
        disconnect()
        %{state | bridge: {:open, bridge_pid, bridge_ref, epoch}}

      _unavailable ->
        schedule_probe(state)
    end
  end

  defp retire_bridge(%{bridge: {:open, bridge_pid, bridge_ref, _epoch}} = state) do
    # Cast/termination is asynchronous; Pack replacement may not adopt until
    # this exact old bridge has stopped.
    AllbertAssistWeb.SignalBridge.close(bridge_pid)
    %{state | bridge: {:retiring, bridge_pid, bridge_ref}}
  end

  defp retire_bridge(state), do: state

  defp admission_reply(%{barrier_pid: barrier_pid, snapshot_digest: digest}),
    do: {:ok, %{barrier_pid: barrier_pid, snapshot_digest: digest}}

  defp admission_reply(:closed), do: {:error, :product_not_ready}

  defp validation_reply(%{barrier_pid: pid, snapshot_digest: digest}, %{
         barrier_pid: pid,
         snapshot_digest: digest
       }),
       do: :ok

  defp validation_reply(_epoch, :closed), do: {:error, :product_not_ready}
  defp validation_reply(_epoch, _ready), do: {:error, :stale_epoch}

  defp attach_lifecycle_validation(socket) do
    socket
    |> Phoenix.LiveView.attach_hook(:allbert_pack_params, :handle_params, &validate_params/3)
    |> Phoenix.LiveView.attach_hook(:allbert_pack_event, :handle_event, &validate_event/3)
    |> Phoenix.LiveView.attach_hook(:allbert_pack_info, :handle_info, &validate_info/2)
    |> Phoenix.LiveView.attach_hook(:allbert_pack_async, :handle_async, &validate_async/3)
  end

  defp validate_params(_params, _uri, socket), do: lifecycle_result(socket)
  defp validate_event(_event, _params, socket), do: lifecycle_result(socket)
  defp validate_info(_message, socket), do: lifecycle_result(socket)
  defp validate_async(_name, _result, socket), do: lifecycle_result(socket)

  defp lifecycle_result(socket) do
    case validate(socket.assigns[:allbert_pack_epoch]) do
      :ok ->
        {:cont, socket}

      {:error, _reason} ->
        disconnect()
        {:halt, Phoenix.LiveView.redirect(socket, to: "/health")}
    end
  end
end
