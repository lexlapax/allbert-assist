defmodule StockSage.TraderBridge do
  @moduledoc """
  Supervised Port wrapper around the StockSage Python bridge.

  Owns a long-lived OS process speaking the JSON-over-stdio protocol defined
  in ADR 0020 and `StockSage.Bridge.Protocol`. Callers reach the bridge
  through `analyze/1` and `ping/0`; both block until the bridge replies, the
  bridge crashes, or the bridge timeout fires.

  When `stocksage.bridge_enabled` is `false`, the GenServer starts but does
  not open a Port. `analyze/1` returns `{:error, :bridge_disabled}` and
  `bridge_status/0` returns `:disabled`.

  Port crashes are isolated. All pending callers receive
  `{:error, :bridge_crashed}` and the GenServer drops the port reference;
  the next call lazily reopens it.
  """

  use GenServer

  alias AllbertAssist.Settings
  alias StockSage.Bridge.Protocol

  require Logger

  # Real TradingAgents `propagate` calls invoke a multi-agent LLM debate
  # workflow that routinely takes 5-10 minutes for a single ticker/date.
  # The default tolerates that runtime; operators can lower this via
  # `stocksage.bridge_timeout_ms` for stub-mode tests or fast paths.
  @default_timeout_ms 600_000
  @default_max_output_bytes 1_048_576
  @line_max_bytes 16_384

  @type analyze_params :: %{
          required(:ticker) => String.t(),
          required(:analysis_date) => String.t(),
          optional(:engine) => String.t(),
          optional(:max_output_bytes) => pos_integer(),
          optional(:force_stub) => boolean(),
          optional(:config) => map()
        }

  @type bridge_status :: :running | :disabled | :crashed | :stopped

  ## Public API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Send a ping; returns :ok when the bridge replies pong before timeout."
  @spec ping(GenServer.server()) :: :ok | {:error, term()}
  def ping(server \\ __MODULE__) do
    case GenServer.call(server, :ping, ping_timeout()) do
      {:ok, "pong"} -> :ok
      {:ok, other} -> {:error, {:unexpected_pong, other}}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:bridge_unavailable, reason}}
  end

  @doc "Run a StockSage analysis through the bridge."
  @spec analyze(analyze_params(), GenServer.server()) :: {:ok, map()} | {:error, term()}
  def analyze(params, server \\ __MODULE__) when is_map(params) do
    GenServer.call(server, {:analyze, params}, request_timeout())
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:bridge_unavailable, reason}}
  end

  @doc "Return bridge status without sending traffic."
  @spec bridge_status(GenServer.server()) :: bridge_status()
  def bridge_status(server \\ __MODULE__) do
    GenServer.call(server, :bridge_status)
  catch
    :exit, _reason -> :stopped
  end

  ## GenServer callbacks

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    state = %{
      port: nil,
      pending: %{},
      buffer: "",
      status: :stopped
    }

    {:ok, ensure_port(state)}
  end

  @impl true
  def handle_call(:bridge_status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call(:ping, from, state) do
    case ensure_port(state) do
      %{status: :disabled} = state ->
        {:reply, {:error, :bridge_disabled}, state}

      %{status: :running, port: port} = state when not is_nil(port) ->
        send_request(state, %{action: "ping"}, from)

      state ->
        {:reply, {:error, :bridge_crashed}, state}
    end
  end

  def handle_call({:analyze, params}, from, state) do
    case ensure_port(state) do
      %{status: :disabled} = state ->
        {:reply, {:error, :bridge_disabled}, state}

      %{status: :running, port: port} = state when not is_nil(port) ->
        send_request(state, build_analyze_request(params), from)

      state ->
        {:reply, {:error, :bridge_crashed}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port, buffer: buffer} = state) do
    full = buffer <> line
    {:noreply, %{state | buffer: ""} |> route_response(full)}
  end

  def handle_info({port, {:data, {:noeol, fragment}}}, %{port: port, buffer: buffer} = state) do
    {:noreply, %{state | buffer: buffer <> fragment}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    Logger.warning("StockSage bridge port exited: #{inspect(reason)}")
    {:noreply, mark_crashed(state)}
  end

  def handle_info({:DOWN, _ref, :port, port, reason}, %{port: port} = state) do
    Logger.warning("StockSage bridge port went DOWN: #{inspect(reason)}")
    {:noreply, mark_crashed(state)}
  end

  def handle_info({:timeout_request, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    safe_close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  ## Internals

  defp ensure_port(state) do
    cond do
      not bridge_enabled?() ->
        if is_port(state.port), do: safe_close(state.port)
        %{state | port: nil, status: :disabled}

      is_port(state.port) and state.status == :running ->
        state

      true ->
        open_port(state)
    end
  end

  defp open_port(state) do
    case bridge_script_path() do
      {:ok, script} ->
        python = python_executable()
        port_opts = [:binary, :exit_status, {:line, @line_max_bytes}, args: [script]]

        try do
          port = Port.open({:spawn_executable, python}, port_opts)
          %{state | port: port, status: :running, buffer: ""}
        rescue
          exception ->
            Logger.warning("StockSage bridge port open failed: #{Exception.message(exception)}")
            %{state | port: nil, status: :crashed}
        catch
          :exit, reason ->
            Logger.warning("StockSage bridge port open error: #{inspect(reason)}")
            %{state | port: nil, status: :crashed}
        end

      {:error, reason} ->
        Logger.warning("StockSage bridge script unavailable: #{inspect(reason)}")
        %{state | port: nil, status: :crashed}
    end
  end

  defp send_request(state, request, from) do
    id = generate_id()
    request_with_id = Map.merge(%{id: id, max_output_bytes: max_output_bytes()}, request)

    case Protocol.encode_request(request_with_id) do
      {:ok, payload} ->
        case safe_command(state.port, payload) do
          :ok ->
            timer = Process.send_after(self(), {:timeout_request, id}, request_timeout())
            pending = Map.put(state.pending, id, %{from: from, timer: timer})
            {:noreply, %{state | pending: pending}}

          {:error, reason} ->
            Logger.warning("StockSage bridge send failed: #{inspect(reason)}")
            {:reply, {:error, :bridge_crashed}, mark_crashed(state)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp route_response(state, line) do
    case Protocol.decode_response(line) do
      {:ok, %{"id" => id} = response} ->
        case Map.pop(state.pending, id) do
          {nil, _pending} ->
            state

          {%{from: from, timer: timer}, pending} ->
            cancel_timer(timer)
            GenServer.reply(from, classify(response))
            %{state | pending: pending}
        end

      {:error, reason} ->
        Logger.warning("StockSage bridge response decode failed: #{inspect(reason)}")
        state
    end
  end

  defp classify(%{"status" => "ok", "result" => result}), do: {:ok, result}
  defp classify(%{"status" => "error", "reason" => reason}), do: {:error, {:bridge_error, reason}}
  defp classify(other), do: {:error, {:invalid_bridge_response, other}}

  defp mark_crashed(state) do
    flush_pending(state.pending, {:error, :bridge_crashed})
    %{state | port: nil, status: :crashed, pending: %{}, buffer: ""}
  end

  defp flush_pending(pending, reply) do
    Enum.each(pending, fn {_id, %{from: from, timer: timer}} ->
      cancel_timer(timer)
      GenServer.reply(from, reply)
    end)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp safe_command(port, payload) do
    Port.command(port, payload)
    :ok
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp safe_close(port) do
    Port.close(port)
    :ok
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp build_analyze_request(params) do
    %{
      action: "run_analysis",
      ticker: Map.get(params, :ticker) || Map.get(params, "ticker"),
      analysis_date: Map.get(params, :analysis_date) || Map.get(params, "analysis_date"),
      engine: Map.get(params, :engine) || Map.get(params, "engine") || "tradingagents"
    }
  end

  defp generate_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp bridge_enabled? do
    case Settings.get("stocksage.bridge_enabled") do
      {:ok, value} when is_boolean(value) -> value
      _other -> true
    end
  rescue
    _exception -> true
  end

  defp request_timeout do
    case Settings.get("stocksage.bridge_timeout_ms") do
      {:ok, value} when is_integer(value) and value > 0 -> value
      _other -> @default_timeout_ms
    end
  rescue
    _exception -> @default_timeout_ms
  end

  defp ping_timeout do
    min(request_timeout(), 5_000)
  end

  defp max_output_bytes do
    case Settings.get("stocksage.bridge_max_output_bytes") do
      {:ok, value} when is_integer(value) and value > 0 -> value
      _other -> @default_max_output_bytes
    end
  rescue
    _exception -> @default_max_output_bytes
  end

  defp python_executable do
    candidate =
      case Settings.get("stocksage.python_path") do
        {:ok, value} when is_binary(value) and value != "" -> value
        _other -> "python3"
      end

    cond do
      Path.type(candidate) == :absolute and File.exists?(candidate) ->
        candidate

      true ->
        System.find_executable(candidate) || candidate
    end
  rescue
    _exception -> System.find_executable("python3") || "python3"
  end

  defp bridge_script_path do
    # __DIR__ resolves to plugins/stocksage/lib/stocksage, so the script lives
    # two levels up under priv/python.
    script = Path.expand("../../priv/python/bridge.py", __DIR__)

    if File.exists?(script) do
      {:ok, script}
    else
      {:error, {:missing_script, script}}
    end
  end
end
