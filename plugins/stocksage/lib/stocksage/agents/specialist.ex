defmodule StockSage.Agents.Specialist do
  @moduledoc false

  defmacro __using__(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    role = Keyword.fetch!(opts, :role)
    type = Keyword.get(opts, :type, :jido_ai)
    spec = StockSage.Agents.spec!(agent_id)
    prompt = File.read!(StockSage.Agents.prompt_path(spec))
    name = agent_id |> String.replace(".", "_")
    description = Keyword.get(opts, :description, "StockSage #{role} specialist.")
    tools = Map.get(spec, :tool_modules, [])

    signal_routes = [
      {"allbert.objectives.delegate.execute", StockSage.Agents.Commands.Execute}
    ]

    agent_use =
      case type do
        :jido_ai ->
          quote do
            use Jido.AI.Agent,
              name: unquote(name),
              description: unquote(description),
              model: :fast,
              tools: unquote(Macro.escape(tools)),
              plugins: [StockSage.Agents.DelegatePlugin],
              system_prompt: unquote(prompt)

            @impl true
            def signal_routes, do: unquote(Macro.escape(signal_routes))

            @impl true
            def signal_routes(_ctx), do: signal_routes()
          end

        :jido ->
          quote do
            use Jido.Agent,
              name: unquote(name),
              description: unquote(description),
              signal_routes: unquote(Macro.escape(signal_routes))
          end
      end

    quote location: :keep do
      @dialyzer {:nowarn_function, __agent_metadata__: 0}
      @dialyzer {:nowarn_function, actions: 0}
      @dialyzer {:nowarn_function, signal_routes: 0}
      @dialyzer {:nowarn_function, signal_routes: 1}
      @dialyzer {:nowarn_function, validate: 2}

      unquote(agent_use)

      @agent_id unquote(agent_id)
      @role unquote(role)

      @spec agent_id() :: String.t()
      def agent_id, do: @agent_id

      @spec role() :: unquote(role)
      def role, do: @role

      @spec metadata() :: map()
      def metadata, do: StockSage.Agents.spec!(@agent_id)

      @spec prompt_path() :: Path.t()
      def prompt_path, do: StockSage.Agents.prompt_path(metadata())

      @spec prompt_version() :: String.t()
      def prompt_version, do: StockSage.Agents.prompt_version()

      def execute(request) when is_map(request) do
        {:ok, StockSage.Agents.Commands.Execute.report_for(@agent_id, request)}
      end

      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []) do
        StockSage.Agents.Runtime.start_link(__MODULE__, @agent_id, opts)
      end

      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(opts) do
        StockSage.Agents.Runtime.child_spec(__MODULE__, @agent_id, opts)
      end

      defoverridable child_spec: 1
    end
  end
end
