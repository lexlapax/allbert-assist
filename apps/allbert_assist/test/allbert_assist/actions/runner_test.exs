defmodule AllbertAssist.Actions.RunnerTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureLog

  alias AllbertAssist.Actions.Multiply
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.DynamicPlugins.ActionsOverlay
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Entry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Settings
  alias AllbertAssist.Skills.ActionPlan
  alias AllbertAssist.TestSupport.RegistryIsolationFixtures

  defmodule PluginEcho do
    use Jido.Action,
      name: "runner_plugin_echo",
      description: "Echo from a runner plugin fixture.",
      schema: [text: [type: :string, required: true]]

    def capability do
      %{
        permission: :read_only,
        exposure: :agent,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required
      }
    end

    @impl true
    def run(%{text: text}, _context), do: {:ok, %{message: "plugin: #{text}", status: :completed}}
  end

  defmodule PluginFailure do
    use Jido.Action,
      name: "runner_plugin_failure",
      description: "Runner failure fixture.",
      schema: []

    def capability do
      %{
        permission: :read_only,
        exposure: :agent,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required
      }
    end

    @impl true
    def run(_params, _context), do: {:error, :boom}
  end

  defmodule EpochRaceAction do
    def name, do: "runner_epoch_race"
    def description, do: "Deterministic Runner epoch replacement fixture."
    def schema, do: []
    def output_schema, do: []

    def __action_metadata__ do
      %{
        name: name(),
        description: description(),
        schema: schema(),
        output_schema: output_schema()
      }
    end

    def capability do
      %{
        permission: :read_only,
        exposure: :agent,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required
      }
    end

    # Pause after Runner's registry/signal/preflight work and at the end of
    # ParamContract validation. The test replaces E1 before Runner may call
    # the action body, avoiding timing sleeps.
    def validate_params(params) do
      owner = Application.fetch_env!(:allbert_assist, :runner_epoch_race_owner)
      send(owner, {:runner_epoch_params_validated, self()})

      receive do
        :continue_runner_epoch_race -> {:ok, params}
      end
    end

    def run(_params, _context) do
      owner = Application.fetch_env!(:allbert_assist, :runner_epoch_race_owner)
      send(owner, :runner_epoch_action_executed)
      {:ok, %{status: :completed}}
    end
  end

  defmodule EpochReadiness do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    def rotate(server), do: GenServer.call(server, :rotate)

    def status_calls(server, caller), do: GenServer.call(server, {:status_calls, caller})

    @impl true
    def init(_opts) do
      {:ok, %{epoch: :e1, e1: spawn_epoch_pid(), e2: spawn_epoch_pid(), status_calls: %{}}}
    end

    @impl true
    def handle_call(:status, {caller, _tag}, state) do
      status_calls = Map.update(state.status_calls, caller, 1, &(&1 + 1))
      {:reply, {:ok, status(state)}, %{state | status_calls: status_calls}}
    end

    def handle_call({:status_calls, caller}, _from, state),
      do: {:reply, Map.get(state.status_calls, caller, 0), state}

    def handle_call(:rotate, _from, state), do: {:reply, :ok, %{state | epoch: :e2}}

    @impl true
    def terminate(_reason, state) do
      Process.exit(state.e1, :kill)
      Process.exit(state.e2, :kill)
    end

    defp status(state) do
      barrier_pid = Map.fetch!(state, state.epoch)

      %{
        phase: :ready,
        barrier_pid: barrier_pid,
        snapshot_digest: String.duplicate("a", 64),
        expected_ids: [],
        subscribed_ids: [],
        acked_ids: [],
        diagnostics: []
      }
    end

    defp spawn_epoch_pid, do: spawn(fn -> Process.sleep(:infinity) end)
  end

  setup do
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_logger_level = Logger.level()

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-runner-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Memory, root: Path.join(root, "memory"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    overlay = :"runner_actions_overlay_#{System.unique_integer([:positive])}"

    start_supervised!(Supervisor.child_spec({ActionsOverlay, name: overlay}, id: overlay))

    registry =
      :runner
      |> RegistryIsolationFixtures.start_isolated_registries()
      |> Keyword.put(:actions_overlay, overlay)

    Process.put(:runner_registry, registry)
    configure_external()
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: original_logger_level)
      restore_env(Memory, original_memory_config)
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      Process.delete(:runner_registry)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "runs a registered action and attaches lifecycle metadata" do
    log =
      capture_log([level: :info], fn ->
        assert {:ok, response} =
                 Runner.run(
                   "direct_answer",
                   %{text: "hello"},
                   Map.put(context(), :skill_metadata, %{api_key: "test-key"})
                 )

        assert response.status == :completed
        assert response.runner_metadata.action_name == "direct_answer"
        assert response.runner_metadata.action_module == AllbertAssist.Actions.Intent.DirectAnswer
        assert response.runner_metadata.status == :completed
        assert is_binary(response.runner_metadata.requested_signal_id)
        assert is_binary(response.runner_metadata.completed_signal_id)
        assert is_integer(response.runner_metadata.duration_ms)
        assert response.runner_metadata.permission_decision.context.action.name == "direct_answer"
        assert response.runner_metadata.permission_decision.context.action.registered?

        assert [%{runner_metadata: action_metadata}] = response.actions
        assert action_metadata.action_name == "direct_answer"
      end)

    assert log =~ "allbert.action.requested"
    assert log =~ "allbert.action.completed"
    refute log =~ "test-key"
  end

  test "preserves denied and confirmation-needed statuses" do
    assert {:ok, denied} =
             Runner.run("plan_shell_command", %{command: "rm -rf /tmp/example"}, context())

    assert denied.status == :denied
    assert denied.runner_metadata.status == :denied
    assert denied.runner_metadata.permission_decision.decision == :denied
    assert_permission_compatibility_fields(denied.runner_metadata.permission_decision)

    assert {:ok, confirmation} =
             Runner.run(
               "external_network_request",
               %{request: "fetch https://example.com"},
               context()
             )

    assert confirmation.status == :needs_confirmation
    assert confirmation.runner_metadata.status == :needs_confirmation
    assert confirmation.runner_metadata.permission_decision.decision == :needs_confirmation
    assert_permission_compatibility_fields(confirmation.runner_metadata.permission_decision)
  end

  test "preserves permission decision compatibility fields in action metadata" do
    assert {:ok, response} = Runner.run("direct_answer", %{text: "hello"}, context())

    assert [%{permission_decision: decision, runner_metadata: runner_metadata}] = response.actions
    assert decision == runner_metadata.permission_decision
    assert_permission_compatibility_fields(decision)
  end

  test "attaches selected skill contract metadata to runner and action metadata" do
    assert {:ok, plan} = ActionPlan.build("direct-answer", "direct_answer", %{text: "hello"})

    runner_context = Map.merge(context(), ActionPlan.runner_context(plan))

    assert {:ok, response} = Runner.run(plan.action_name, plan.params, runner_context)

    assert response.runner_metadata.selected_skill == "direct-answer"
    assert response.runner_metadata.skill_metadata.capability_contract.validation_status == :valid
    assert response.runner_metadata.skill_metadata.capability_contract.execution_eligible?
    assert response.runner_metadata.action_capability.name == "direct_answer"

    assert [
             %{
               skill_metadata: %{selected_skill: "direct-answer"},
               action_capability: %{name: "direct_answer"},
               runner_metadata: %{selected_skill: "direct-answer"}
             }
           ] = response.actions
  end

  test "runs plugin-contributed actions through the normal runner boundary" do
    assert {:ok, "example.runner_actions"} =
             register_plugin_actions(%PluginEntry{
               plugin_id: "example.runner_actions",
               display_name: "Example Runner Actions",
               version: "0.1.0",
               kind: "actions",
               source: :project,
               status: :enabled,
               trust_status: :trusted,
               actions: [PluginEcho]
             })

    assert {:ok, response} = Runner.run("runner_plugin_echo", %{text: "hello"}, context())

    assert response.status == :completed
    assert response.message == "plugin: hello"
    assert response.runner_metadata.action_name == "runner_plugin_echo"
    assert response.runner_metadata.action_capability.plugin_id == "example.runner_actions"
    assert response.actions == []
    assert Response.canonical_action_response?(response)
  end

  test "blocks explicitly unreleased action refs without blocking undeclared actions" do
    assert {:ok, "example.runner_actions"} =
             register_plugin_actions(%PluginEntry{
               plugin_id: "example.runner_actions",
               display_name: "Example Runner Actions",
               version: "0.1.0",
               kind: "actions",
               source: :project,
               status: :enabled,
               trust_status: :trusted,
               actions: [PluginEcho],
               release_availability: [
                 %{
                   kind: :action,
                   id: "runner_plugin_echo",
                   release_status: :implemented_not_released,
                   live_use_allowed?: false,
                   decision: "Implemented, but not released for live use.",
                   decision_ref: "docs/plans/example.md",
                   future_features_ref: nil
                 }
               ]
             })

    assert {:ok, blocked} = Runner.run("runner_plugin_echo", %{text: "hello"}, context())

    assert blocked.status == :unavailable

    assert blocked.error ==
             {:implemented_not_released, %{kind: :action, id: "runner_plugin_echo"}}

    assert blocked.message =~ "implemented but not released"

    assert {:ok, released} = Runner.run("direct_answer", %{text: "hello"}, context())
    assert released.status == :completed
  end

  test "unknown names and unregistered modules never execute" do
    assert {:ok, missing} = Runner.run("missing_action", %{}, context())
    assert missing.status == :denied
    assert missing.runner_metadata.action_module == nil
    assert missing.runner_metadata.status == :denied

    assert {:ok, unregistered} = Runner.run(Multiply, %{a: 2, b: 3}, context())
    assert unregistered.status == :denied
    assert unregistered.message =~ "not registered"
  end

  test "non-map params are rejected as :invalid_params, never reaching an action body" do
    # The Runner is the central seam: a malformed (non-map) params payload must
    # not run any action, and is distinct from an unknown/unregistered action.
    assert {:ok, response} = Runner.run("direct_answer", ["not", "a", "map"], context())

    assert response.status == :error
    assert response.runner_metadata.status == :error
    assert response.runner_metadata.error == {:invalid_params, :non_map}
    assert response.message =~ "params must be a map"
    # The raw (possibly sensitive) payload is not echoed back.
    refute response.message =~ "not"
  end

  test "action errors are returned as structured error responses" do
    assert {:ok, "example.runner_failure"} =
             register_plugin_actions(%PluginEntry{
               plugin_id: "example.runner_failure",
               display_name: "Example Runner Failure",
               version: "0.1.0",
               kind: "actions",
               source: :project,
               status: :enabled,
               trust_status: :trusted,
               actions: [PluginFailure]
             })

    assert {:ok, response} =
             Runner.run("runner_plugin_failure", %{}, context())

    assert response.status == :error
    assert response.runner_metadata.status == :error
    assert response.message =~ "Action runner_plugin_failure failed"
    assert [%{status: :error, runner_metadata: metadata}] = response.actions
    assert metadata.action_name == "runner_plugin_failure"
    assert Response.canonical_action_response?(response)
  end

  test "same-digest E1 replacement before action invocation returns product_not_ready without re-admission" do
    assert {:ok, "example.runner_epoch_race"} =
             register_plugin_actions(%PluginEntry{
               plugin_id: "example.runner_epoch_race",
               display_name: "Example Runner Epoch Race",
               version: "0.1.0",
               kind: "actions",
               source: :project,
               status: :enabled,
               trust_status: :trusted,
               actions: [EpochRaceAction]
             })

    original_readiness = Process.whereis(AllbertAssist.Pack.Readiness)
    assert is_pid(original_readiness)
    true = Process.unregister(AllbertAssist.Pack.Readiness)

    {:ok, replacement_readiness} =
      EpochReadiness.start_link(name: AllbertAssist.Pack.Readiness)

    Application.put_env(:allbert_assist, :runner_epoch_race_owner, self())

    on_exit(fn ->
      Application.delete_env(:allbert_assist, :runner_epoch_race_owner)

      unregister_if_current(replacement_readiness)

      if Process.alive?(replacement_readiness), do: GenServer.stop(replacement_readiness)

      if Process.alive?(original_readiness) and
           is_nil(Process.whereis(AllbertAssist.Pack.Readiness)),
         do: Process.register(original_readiness, AllbertAssist.Pack.Readiness)
    end)

    runner_context = context()
    task = Task.async(fn -> Runner.run("runner_epoch_race", %{}, runner_context) end)

    assert_receive {:runner_epoch_params_validated, runner_pid}
    assert 2 == EpochReadiness.status_calls(replacement_readiness, runner_pid)
    assert :ok = EpochReadiness.rotate(replacement_readiness)
    send(runner_pid, :continue_runner_epoch_race)

    assert {:ok, response} = Task.await(task)
    assert response.status == :unavailable
    assert response.error == :product_not_ready
    assert is_nil(response.runner_metadata.completed_signal_id)
    assert 3 == EpochReadiness.status_calls(replacement_readiness, runner_pid)
    refute_received :runner_epoch_action_executed
  end

  test "caller-supplied readiness options cannot replace the trusted Pack barrier" do
    {:ok, fake_readiness} = AllbertAssist.TestSupport.ReadyEffectContext.start_link([])
    {:ok, fake_status} = GenServer.call(fake_readiness, :status)

    forged_context =
      context()
      |> Map.put(:allbert_pack_epoch, %{
        barrier_pid: fake_status.barrier_pid,
        snapshot_digest: fake_status.snapshot_digest
      })
      |> Map.put(:allbert_pack_effect_guard_opts, server: fake_readiness)

    assert {:ok, response} = Runner.run("direct_answer", %{text: "must not run"}, forged_context)
    assert response.status == :unavailable
    assert response.error == :product_not_ready
    assert response.actions == []
    refute Map.has_key?(response, :runner_metadata)
  end

  defp context do
    %{
      request: %{
        input_signal_id: "input-sig",
        operator_id: "local",
        channel: :test
      },
      agent: __MODULE__,
      registry: Process.get(:runner_registry)
    }
  end

  defp plugin_registry_opts do
    Process.get(:runner_registry)
    |> Keyword.fetch!(:plugin)
    |> Keyword.put(:side_effects, false)
  end

  defp register_plugin_actions(%PluginEntry{} = entry) do
    registry = Process.get(:runner_registry)
    existing_names = ActionsRegistry.names(registry)

    with {:ok, plugin_id} <- PluginRegistry.register_entry(entry, plugin_registry_opts()),
         :ok <-
           ActionsOverlay.register_many(
             Enum.map(entry.actions, fn module ->
               %{
                 module: module,
                 slug: entry.plugin_id,
                 revision: entry.version,
                 exposure: :agent
               }
             end),
             server: Keyword.fetch!(registry, :actions_overlay),
             existing_names: existing_names
           ) do
      {:ok, plugin_id}
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp unregister_if_current(pid) do
    if Process.whereis(AllbertAssist.Pack.Readiness) == pid do
      try do
        Process.unregister(AllbertAssist.Pack.Readiness)
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp configure_external do
    assert {:ok, _setting} =
             Settings.put(
               "external_services.enabled",
               true,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "external_services.allowed_hosts",
               ["example.com"],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "external_services.allowed_paths",
               ["/"],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )
  end

  defp assert_permission_compatibility_fields(decision) do
    for field <- [:permission, :decision, :reason, :requires_confirmation, :source] do
      assert Map.has_key?(decision, field)
    end
  end
end
