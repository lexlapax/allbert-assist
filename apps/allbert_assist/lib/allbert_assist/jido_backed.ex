defmodule AllbertAssist.JidoBacked do
  @moduledoc """
  Shared substrate for Jido.Agent-backed internal coordinators.

  v0.23 uses this for state machines whose authoritative state already lives
  somewhere durable: confirmation YAML under Allbert Home and scheduled-job
  rows in SQLite. The agent process is a coordinator and rebuildable
  projection, not a new security or persistence boundary.
  """

  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings
  alias Jido.AgentServer
  alias Jido.Signal

  @default_debug_agents [
    {AllbertAssist.Confirmations.Store.Agent, AllbertAssist.Confirmations.Store.Agent},
    {AllbertAssist.Jobs.Scheduler.Agent, AllbertAssist.Jobs.Scheduler}
  ]

  @type debug_agent :: {module(), GenServer.server()}
  @type dispatch_result :: {:ok, term()} | {:error, term()}

  @callback rebuild_state(keyword()) :: {:ok, map()} | {:error, term()}
  @callback command_modules() :: [module()]

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.get(opts, :description, "Allbert JidoBacked coordinator.")
    schema = Keyword.get(opts, :schema, [])
    signal_routes = Keyword.get(opts, :signal_routes, [])

    quote location: :keep do
      @behaviour AllbertAssist.JidoBacked

      @dialyzer {:nowarn_function, __agent_metadata__: 0}
      @dialyzer {:nowarn_function, actions: 0}
      @dialyzer {:nowarn_function, signal_routes: 0}
      @dialyzer {:nowarn_function, validate: 2}

      use Jido.Agent,
        name: unquote(name),
        description: unquote(description),
        schema: unquote(schema),
        signal_routes: unquote(signal_routes)

      @doc "Start the Jido AgentServer for this coordinator."
      @spec start_link() :: GenServer.on_start()
      def start_link, do: start_link([])

      @doc "Start the Jido AgentServer for this coordinator."
      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts) do
        AllbertAssist.JidoBacked.start_link(__MODULE__, opts)
      end

      @doc false
      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(opts) do
        AllbertAssist.JidoBacked.child_spec(__MODULE__, opts)
      end

      defoverridable start_link: 0, start_link: 1, child_spec: 1
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

    expected_command = Keyword.get(opts, :expected_command)

    case AgentServer.call(server, signal, timeout) do
      {:ok, agent} -> unwrap_last_result(agent.state, expected_command)
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
  Return a bounded markdown trace section for JidoBacked agent diagnostics.

  Default operator traces stay byte-identical because the section is emitted
  only when `allbert.jido.debug_trace` is explicitly enabled.
  """
  @spec debug_trace_markdown([debug_agent()]) :: String.t()
  def debug_trace_markdown(agents \\ debug_agents()) do
    if debug_trace_enabled?() do
      body =
        agents
        |> Enum.map(&debug_agent_line/1)
        |> Enum.join("\n")

      "\n\n## Jido Debug\n\n#{body}"
    else
      ""
    end
  end

  @doc "Return JidoBacked agents included in the generic trace debug section."
  @spec debug_agents() :: [debug_agent()]
  def debug_agents do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:debug_agents, [])
    |> case do
      agents when is_list(agents) -> @default_debug_agents ++ agents
      _other -> @default_debug_agents
    end
  end

  defp unwrap_last_result(state, expected_command) do
    with :ok <- ensure_expected_command(state, expected_command) do
      unwrap_last_result(state)
    end
  end

  defp unwrap_last_result(%{last_result: {:ok, result}}), do: {:ok, result}
  defp unwrap_last_result(%{last_result: {:error, reason}}), do: {:error, reason}
  defp unwrap_last_result(%{"last_result" => {:ok, result}}), do: {:ok, result}
  defp unwrap_last_result(%{"last_result" => {:error, reason}}), do: {:error, reason}
  defp unwrap_last_result(_state), do: {:ok, :dispatched}

  defp ensure_expected_command(_state, nil), do: :ok

  defp ensure_expected_command(state, expected_command) do
    last_command = state_value(state, :last_command)

    if command_matches?(last_command, expected_command) do
      :ok
    else
      {:error,
       {:stale_jido_backed_result,
        %{expected_command: expected_command, last_command: last_command || :unknown}}}
    end
  end

  defp command_matches?(command, expected),
    do: command == expected or command == Atom.to_string(expected)

  defp debug_agent_line({agent_module, server}) do
    case Process.whereis(server) do
      nil ->
        "- #{inspect(agent_module)}: unavailable"

      _pid ->
        case AgentServer.state(server) do
          {:ok, server_state} ->
            "- #{inspect(agent_module)}: #{debug_agent_summary(server_state)}"

          {:error, reason} ->
            "- #{inspect(agent_module)}: unavailable reason=#{bounded_debug_value(reason)}"
        end
    end
  rescue
    exception ->
      "- #{inspect(agent_module)}: unavailable reason=#{bounded_debug_value(Exception.message(exception))}"
  catch
    kind, reason ->
      "- #{inspect(agent_module)}: unavailable reason=#{bounded_debug_value({kind, reason})}"
  end

  defp debug_agent_summary(%{status: status, agent: %{state: state}}) when is_map(state) do
    [
      "server_status=#{status}",
      "last_command=#{state_value(state, :last_command) || "unknown"}",
      "last_result=#{last_result_status(state_value(state, :last_result))}",
      "pending_count=#{pending_count(state)}",
      "last_tick_at=#{state_value(state, :last_tick_at) || "none"}",
      "last_summary=#{bounded_debug_value(state_value(state, :last_summary) || "none")}",
      "last_rebuilt_at=#{state_value(state, :last_rebuilt_at) || "none"}",
      "last_error=#{bounded_debug_value(state_value(state, :last_error) || "none")}"
    ]
    |> Enum.join(" ")
  end

  defp debug_agent_summary(_server_state), do: "unavailable reason=unexpected_state"

  defp state_value(state, key) when is_map(state) do
    Map.get(state, key) || Map.get(state, Atom.to_string(key))
  end

  defp last_result_status({:ok, _result}), do: "ok"
  defp last_result_status({:error, _reason}), do: "error"
  defp last_result_status(other), do: bounded_debug_value(other || "unknown")

  defp pending_count(state) do
    case state_value(state, :pending_ids) do
      ids when is_list(ids) -> length(ids)
      _other -> "n/a"
    end
  end

  defp bounded_debug_value(value) do
    value
    |> Redactor.redact()
    |> inspect(limit: 20, printable_limit: 240)
    |> then(fn text ->
      if byte_size(text) > 240, do: binary_part(text, 0, 240), else: text
    end)
  end

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
