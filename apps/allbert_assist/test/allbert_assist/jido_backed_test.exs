defmodule AllbertAssist.JidoBackedTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Confirmations.Store
  alias AllbertAssist.Confirmations.Store.Agent, as: StoreAgent
  alias AllbertAssist.JidoBacked
  alias AllbertAssist.Settings
  alias Jido.AgentServer

  defmodule SchemaOnlyAgent do
    use AllbertAssist.JidoBacked,
      name: "schema_only_agent",
      description: "Schema-only test agent with no signal routes.",
      schema: [
        active_objectives: [type: :map, default: %{}],
        current_stage: [type: :atom, default: :idle]
      ]

    @impl true
    def rebuild_state(_opts), do: {:ok, %{active_objectives: %{}, current_stage: :rebuilt}}

    @impl true
    def command_modules, do: []
  end

  defmodule DirectiveListCommand do
    use Jido.Action,
      name: "test_directive_list",
      description: "Returns only an empty state patch plus a directive list."

    alias Jido.Agent.Directive
    alias Jido.Signal

    @impl true
    def run(_params, _context) do
      {:ok, %{}, [Directive.schedule(60_000, Signal.new!("test.never", %{}))]}
    end
  end

  defmodule DirectiveSingleCommand do
    use Jido.Action,
      name: "test_directive_single",
      description: "Returns only an empty state patch plus one directive."

    alias Jido.Agent.Directive
    alias Jido.Signal

    @impl true
    def run(_params, _context) do
      {:ok, %{}, Directive.schedule(60_000, Signal.new!("test.never", %{}))}
    end
  end

  defmodule DirectiveOnlyAgent do
    use AllbertAssist.JidoBacked,
      name: "directive_only_agent",
      description: "Directive-only test agent.",
      signal_routes: [
        {"test.directive_list", AllbertAssist.JidoBackedTest.DirectiveListCommand},
        {"test.directive_single", AllbertAssist.JidoBackedTest.DirectiveSingleCommand}
      ]

    @impl true
    def rebuild_state(_opts), do: {:ok, %{mode: :directive_only}}

    @impl true
    def command_modules,
      do: [
        AllbertAssist.JidoBackedTest.DirectiveListCommand,
        AllbertAssist.JidoBackedTest.DirectiveSingleCommand
      ]
  end

  setup do
    original_jido_backed_config = Application.get_env(:allbert_assist, JidoBacked)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-jido-backed-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(JidoBacked, original_jido_backed_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "debug trace setting is default off and writable" do
    assert {:ok, false} = Settings.get("allbert.jido.debug_trace")
    refute JidoBacked.debug_trace_enabled?()

    assert {:ok, resolved} =
             Settings.put("allbert.jido.debug_trace", true, %{audit?: false})

    assert resolved.value == true
    assert JidoBacked.debug_trace_enabled?()
  end

  test "macro supports schema-only agents for v0.24 objective engine shape" do
    agent = SchemaOnlyAgent.new()

    assert agent.state.active_objectives == %{}
    assert agent.state.current_stage == :idle
    assert SchemaOnlyAgent.signal_routes() == []

    name = :"schema_only_agent_#{System.unique_integer([:positive])}"
    start_supervised!({SchemaOnlyAgent, name: name})

    assert {:ok, %{agent: %{state: %{current_stage: :rebuilt}}}} = AgentServer.state(name)
  end

  test "debug agent list can be extended without editing JidoBacked" do
    name = :"schema_only_debug_agent_#{System.unique_integer([:positive])}"
    Application.put_env(:allbert_assist, JidoBacked, debug_agents: [{SchemaOnlyAgent, name}])

    assert {SchemaOnlyAgent, name} in JidoBacked.debug_agents()
  end

  test "private confirmation command modules are not registered capability actions" do
    for module <- StoreAgent.command_modules() do
      refute Registry.registered_module?(module)
      assert {:error, {:unknown_action, ^module}} = Registry.capability(module)
    end
  end

  test "dispatch through a JidoBacked agent unwraps command results" do
    assert {:ok, record} =
             Store.create(%{
               origin: %{actor: "local", channel: :test},
               target_action: %{name: "direct_answer"},
               target_permission: :read_only,
               target_execution_mode: :read_only,
               security_decision: %{permission: :read_only, decision: :allowed},
               params_summary: %{message: "hello"}
             })

    assert {:ok, ^record} =
             JidoBacked.dispatch(
               StoreAgent,
               "allbert.confirmations.store.read",
               %{id: record["id"]},
               source: "/test"
             )
  end

  test "dispatch treats directive-only commands as successful dispatches" do
    name = :"directive_only_agent_#{System.unique_integer([:positive])}"

    start_supervised!(
      {DirectiveOnlyAgent,
       name: name, initial_state: %{mode: :directive_only, last_error: "stale"}}
    )

    assert {:ok, :dispatched} =
             JidoBacked.dispatch(name, "test.directive_list", %{}, source: "/test")

    assert {:ok, :dispatched} =
             JidoBacked.dispatch(name, "test.directive_single", %{}, source: "/test")
  end

  test "dispatch can reject stale last_result for commands that require a fresh result" do
    name = :"stale_result_agent_#{System.unique_integer([:positive])}"

    start_supervised!(
      {DirectiveOnlyAgent,
       name: name,
       initial_state: %{mode: :directive_only, last_command: :rebuild, last_result: {:ok, :stale}}}
    )

    assert {:error,
            {:stale_jido_backed_result,
             %{expected_command: :directive_list, last_command: :rebuild}}} =
             JidoBacked.dispatch(name, "test.directive_list", %{},
               source: "/test",
               expected_command: :directive_list
             )
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
