defmodule AllbertAssist.JidoBacked do
  @moduledoc """
  Shared substrate for Jido.Agent-backed internal coordinators.

  v0.23 uses this for state machines whose authoritative state already lives
  somewhere durable: confirmation YAML under Allbert Home and scheduled-job
  rows in SQLite. The agent process is a coordinator and rebuildable
  projection, not a new security or persistence boundary.
  """

  alias AllbertAssist.Settings
  alias Jido.AgentServer
  alias Jido.Signal

  @type dispatch_result :: {:ok, term()} | {:error, term()}

  @callback rebuild_state(keyword()) :: {:ok, map()} | {:error, term()}
  @callback command_modules() :: [module()]
  @callback emit_debug_trace?(map()) :: boolean()

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.get(opts, :description, "Allbert JidoBacked coordinator.")
    signal_routes = Keyword.fetch!(opts, :signal_routes)

    quote location: :keep do
      @behaviour AllbertAssist.JidoBacked

      use Jido.Agent,
        name: unquote(name),
        description: unquote(description),
        schema: [],
        signal_routes: unquote(Macro.escape(signal_routes))

      @doc "Start the Jido AgentServer for this coordinator."
      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []) do
        AllbertAssist.JidoBacked.start_link(__MODULE__, opts)
      end

      @doc false
      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(opts) do
        AllbertAssist.JidoBacked.child_spec(__MODULE__, opts)
      end
    end
  end

  @doc "Start an AgentServer for a JidoBacked module."
  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(module, opts) when is_atom(module) and is_list(opts) do
    name = Keyword.get(opts, :name, module)
    id = Keyword.get(opts, :id, default_id(module))

    initial_state =
      Keyword.get_lazy(opts, :initial_state, fn ->
        case module.rebuild_state(opts) do
          {:ok, state} -> state
          {:error, reason} -> error_state(reason)
        end
      end)

    AgentServer.start_link(
      jido: Keyword.get(opts, :jido, AllbertAssist.Jido),
      agent: module,
      id: id,
      initial_state: initial_state,
      name: name,
      debug: Keyword.get(opts, :debug, false)
    )
  end

  @doc "Return a child spec for a JidoBacked module."
  @spec child_spec(module(), keyword()) :: Supervisor.child_spec()
  def child_spec(module, opts) when is_atom(module) and is_list(opts) do
    %{
      id: Keyword.get(opts, :child_id, module),
      start: {module, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc "Dispatch a signal to a JidoBacked agent and unwrap its last command result."
  @spec dispatch(GenServer.server(), String.t(), map(), keyword()) :: dispatch_result()
  def dispatch(server, signal_type, data, opts \\ [])
      when is_binary(signal_type) and is_map(data) and is_list(opts) do
    source = Keyword.get(opts, :source, "/allbert/jido_backed")
    timeout = Keyword.get(opts, :timeout, :infinity)

    signal = Signal.new!(signal_type, data, source: source)

    case AgentServer.call(server, signal, timeout) do
      {:ok, agent} -> unwrap_last_result(agent.state)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Return whether Jido debug trace output is enabled."
  @spec debug_trace_enabled?() :: boolean()
  def debug_trace_enabled? do
    case Settings.get("allbert.jido.debug_trace") do
      {:ok, true} -> true
      _other -> false
    end
  end

  @doc """
  Gate for future bounded debug trace emission.

  v0.23 keeps default operator traces byte-identical. The hook exists so
  converted coordinators can expose bounded state when the explicit setting is
  enabled, without changing their public result shape.
  """
  @spec maybe_emit_debug_trace(map(), atom(), map()) :: :ok
  def maybe_emit_debug_trace(state, _event, _context) when is_map(state) do
    _enabled? = debug_trace_enabled?()
    :ok
  end

  defp unwrap_last_result(%{last_result: {:ok, result}}), do: {:ok, result}
  defp unwrap_last_result(%{last_result: {:error, reason}}), do: {:error, reason}
  defp unwrap_last_result(%{"last_result" => {:ok, result}}), do: {:ok, result}
  defp unwrap_last_result(%{"last_result" => {:error, reason}}), do: {:error, reason}
  defp unwrap_last_result(_state), do: {:error, :jido_backed_missing_result}

  defp default_id(module) do
    module
    |> Module.split()
    |> Enum.join(".")
  end

  defp error_state(reason) do
    %{
      last_command: :rebuild,
      last_result: {:error, reason},
      last_error: inspect(reason),
      last_rebuilt_at: nil
    }
  end
end
