defmodule StockSage.Agents.Specialist do
  @moduledoc false

  defmacro __using__(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    role = Keyword.fetch!(opts, :role)
    name = agent_id |> String.replace(".", "_")
    description = Keyword.get(opts, :description, "StockSage #{role} specialist.")

    signal_routes = [
      {"allbert.objectives.delegate.execute", StockSage.Agents.Commands.Execute}
    ]

    quote location: :keep do
      @dialyzer {:nowarn_function, __agent_metadata__: 0}
      @dialyzer {:nowarn_function, actions: 0}
      @dialyzer {:nowarn_function, signal_routes: 0}
      @dialyzer {:nowarn_function, validate: 2}

      # The OTP process is a deterministic Jido signal router. The LLM
      # boundary lives inside `StockSage.Agents.Commands.Execute`, which calls
      # `Jido.AI.generate_object/3` with bounded schemas and settings-driven
      # model profiles. Keeping the process as `Jido.Agent` preserves
      # `AgentServer.call/3` signal-route semantics while still letting
      # non-quality specialists use Jido.AI for report generation.
      use Jido.Agent,
        name: unquote(name),
        description: unquote(description),
        signal_routes: unquote(Macro.escape(signal_routes))

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
