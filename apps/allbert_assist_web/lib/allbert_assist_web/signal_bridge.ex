defmodule AllbertAssistWeb.SignalBridge do
  @moduledoc """
  Bridges objective and workspace lifecycle signals from Jido.Signal.Bus to
  Phoenix.PubSub.

  The bridge is web-only. Headless CLI deployments do not need it; signals
  still publish normally through the core signal bus.
  """

  use GenServer, restart: :temporary

  require Logger

  alias AllbertAssist.Objectives
  alias AllbertAssist.Workspace.Fragment
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias Jido.Signal
  alias Jido.Signal.Bus

  @objective_pattern "allbert.objective.**"
  @fanout_pattern "allbert.objectives.**"
  @workspace_pattern "allbert.workspace.**"
  @topic_prefix "objectives:"
  @workspace_topic_prefix "workspace:"

  @spec topic_for(String.t()) :: String.t()
  def topic_for(user_id) when is_binary(user_id), do: @topic_prefix <> user_id

  @spec workspace_topic_for(String.t(), String.t()) :: String.t()
  def workspace_topic_for(user_id, thread_id) when is_binary(user_id) and is_binary(thread_id) do
    @workspace_topic_prefix <> user_id <> ":" <> thread_id
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @doc false
  @spec open(pid() | GenServer.name(), map()) :: :ok | {:error, :unavailable}
  def open(server, epoch) when is_map(epoch) do
    GenServer.call(server, {:open, epoch}, 100)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc false
  @spec close(pid() | GenServer.name()) :: :ok
  def close(server) do
    GenServer.cast(server, :close)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       subscription_ids: %{},
       epoch: nil,
       subscribe_fun: Keyword.get(opts, :subscribe_fun, &Bus.subscribe/2),
       unsubscribe_fun: Keyword.get(opts, :unsubscribe_fun, &Bus.unsubscribe/2),
       validate_fun: Keyword.get(opts, :validate_fun, &AllbertAssistWeb.PackReadiness.validate/1)
     }}
  end

  @impl true
  def handle_call({:open, epoch}, _from, state) do
    if state.validate_fun.(epoch) != :ok do
      {:reply, {:error, :unavailable}, state}
    else
      open_validated(epoch, state)
    end
  end

  defp open_validated(epoch, state) do
    if epoch == state.epoch do
      {:reply, :ok, state}
    else
      state = close_subscriptions(state)

      subscription_ids =
        %{
          objective: @objective_pattern,
          fanout: @fanout_pattern,
          workspace: @workspace_pattern
        }
        |> Enum.map(fn {kind, pattern} ->
          {kind, subscribe(kind, pattern, epoch, state)}
        end)
        |> Map.new()

      next_state = %{state | subscription_ids: subscription_ids, epoch: epoch}

      if Enum.all?(subscription_ids, fn {_kind, id} -> is_binary(id) end) do
        AllbertAssistWeb.PackReadiness.disconnect()
        {:reply, :ok, next_state}
      else
        {:reply, {:error, :unavailable}, close_subscriptions(next_state)}
      end
    end
  end

  @impl true
  def handle_cast(:close, state), do: {:stop, :normal, close_subscriptions(state)}

  @impl true
  def terminate(_reason, state), do: close_subscriptions(state)

  @impl true
  def handle_info({:signal, %Signal{} = signal}, state) do
    if state.validate_fun.(state.epoch) == :ok do
      cond do
        String.starts_with?(signal.type, "allbert.objective.") or
            String.starts_with?(signal.type, "allbert.objectives.") ->
          broadcast_objective(signal)

        signal.type == "allbert.workspace.fragment.emitted" ->
          broadcast_fragment(signal)

        String.starts_with?(signal.type, "allbert.workspace.") ->
          broadcast_workspace(signal)

        true ->
          :ok
      end
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp broadcast_objective(%Signal{data: data} = signal) when is_map(data) do
    case signal_user_id(data) do
      user_id when is_binary(user_id) and user_id != "" ->
        Phoenix.PubSub.broadcast(
          AllbertAssistWeb.PubSub,
          topic_for(user_id),
          {:objective_event, signal}
        )

      _missing ->
        :ok
    end
  end

  defp broadcast_objective(_signal), do: :ok

  defp signal_user_id(data) do
    durable_objective_user(data) || Map.get(data, :user_id) || Map.get(data, "user_id")
  end

  defp durable_objective_user(data) do
    objective_id =
      Map.get(data, :parent_id) || Map.get(data, "parent_id") ||
        Map.get(data, :child_id) || Map.get(data, "child_id") ||
        Map.get(data, :objective_id) || Map.get(data, "objective_id")

    if is_binary(objective_id), do: safely_resolve_objective_user(objective_id)
  end

  defp safely_resolve_objective_user(objective_id) do
    case Objectives.get_objective(objective_id) do
      {:ok, objective} -> objective.user_id
      _missing -> nil
    end
  rescue
    _repo_unavailable -> nil
  catch
    :exit, _repo_unavailable -> nil
  end

  defp subscribe(kind, pattern, epoch, %{subscribe_fun: subscribe_fun, validate_fun: validate_fun}) do
    if validate_fun.(epoch) != :ok do
      nil
    else
      subscribe_once(kind, pattern, subscribe_fun)
    end
  end

  defp subscribe_once(kind, pattern, subscribe_fun) do
    case subscribe_fun.(AllbertAssist.SignalBus, pattern) do
      {:ok, subscription_id} ->
        subscription_id

      {:error, reason} ->
        Logger.warning("#{kind} signal bridge subscription failed: #{inspect(reason)}")
        nil
    end
  end

  defp close_subscriptions(state) do
    Enum.each(state.subscription_ids, fn
      {_kind, subscription_id} when is_binary(subscription_id) ->
        _ = state.unsubscribe_fun.(AllbertAssist.SignalBus, subscription_id)

      _other ->
        :ok
    end)

    %{state | subscription_ids: %{}, epoch: nil}
  rescue
    _ -> %{state | subscription_ids: %{}, epoch: nil}
  end

  defp broadcast(%Signal{data: data} = signal, event) when is_map(data) do
    case Map.get(data, :user_id) || Map.get(data, "user_id") do
      user_id when is_binary(user_id) and user_id != "" ->
        Phoenix.PubSub.broadcast(
          AllbertAssistWeb.PubSub,
          topic_for(user_id),
          {event, signal}
        )

      _other ->
        :ok
    end
  end

  defp broadcast(_signal, _event), do: :ok

  defp broadcast_workspace(%Signal{data: data} = signal) when is_map(data) do
    user_id = Map.get(data, :user_id) || Map.get(data, "user_id")
    thread_id = Map.get(data, :thread_id) || Map.get(data, "thread_id")

    if is_binary(user_id) and user_id != "" and is_binary(thread_id) and thread_id != "" do
      Phoenix.PubSub.broadcast(
        AllbertAssistWeb.PubSub,
        workspace_topic_for(user_id, thread_id),
        {:workspace_event, signal}
      )
    else
      broadcast(signal, :workspace_event)
    end
  end

  defp broadcast_workspace(signal), do: broadcast(signal, :workspace_event)

  defp broadcast_fragment(%Signal{data: data} = signal) when is_map(data) do
    case Fragment.validate_received(signal) do
      {:ok, envelope} ->
        broadcast_validated_fragment(envelope)

      {:error, reason} ->
        Logger.debug("workspace fragment receive skipped reason=#{inspect(reason)}")
        :ok
    end
  end

  defp broadcast_fragment(signal), do: broadcast_workspace(signal)

  defp broadcast_validated_fragment(envelope) do
    case envelope do
      %Envelope{user_id: user_id} when is_binary(user_id) and user_id != "" ->
        Phoenix.PubSub.broadcast(
          AllbertAssistWeb.PubSub,
          topic_for(user_id),
          {:fragment, envelope}
        )

      _other ->
        :ok
    end
  end
end
