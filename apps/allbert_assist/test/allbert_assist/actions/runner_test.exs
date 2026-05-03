defmodule AllbertAssist.Actions.RunnerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AllbertAssist.Actions.Multiply
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Skills.ActionPlan

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
    configure_external()
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: original_logger_level)
      restore_env(Memory, original_memory_config)
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "runs a registered action and attaches lifecycle metadata" do
    log =
      capture_log([level: :info], fn ->
        assert {:ok, response} =
                 Runner.run("direct_answer", %{text: "hello", api_key: "test-key"}, context())

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

  test "unknown names and unregistered modules never execute" do
    assert {:ok, missing} = Runner.run("missing_action", %{}, context())
    assert missing.status == :denied
    assert missing.runner_metadata.action_module == nil
    assert missing.runner_metadata.status == :denied

    assert {:ok, unregistered} = Runner.run(Multiply, %{a: 2, b: 3}, context())
    assert unregistered.status == :denied
    assert unregistered.message =~ "not registered"
  end

  test "action errors are returned as structured error responses" do
    assert {:ok, response} =
             Runner.run(
               "update_setting",
               %{key: "operator.communication_style"},
               context()
             )

    assert response.status == :error
    assert response.runner_metadata.status == :error
    assert response.message =~ "Action update_setting failed"
    assert [%{status: :error, runner_metadata: metadata}] = response.actions
    assert metadata.action_name == "update_setting"
  end

  defp context do
    %{
      request: %{
        input_signal_id: "input-sig",
        operator_id: "local",
        channel: :test
      },
      agent: __MODULE__
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/"], %{audit?: false})
  end

  defp assert_permission_compatibility_fields(decision) do
    for field <- [:permission, :decision, :reason, :requires_confirmation, :source] do
      assert Map.has_key?(decision, field)
    end
  end
end
