defmodule AllbertAssist.Actions.IntentActionsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Intent.ActivateSkill
  alias AllbertAssist.Actions.Intent.AppendMemory
  alias AllbertAssist.Actions.Intent.ExternalNetworkRequest
  alias AllbertAssist.Actions.Intent.ListSkills
  alias AllbertAssist.Actions.Intent.PlanShellCommand
  alias AllbertAssist.Actions.Intent.ReadRecentMemory
  alias AllbertAssist.Actions.Intent.ReadSkill
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_config = Application.get_env(:allbert_assist, Memory)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-action-memory-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Memory, root: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    configure_external()

    on_exit(fn ->
      if original_config do
        Application.put_env(:allbert_assist, Memory, original_config)
      else
        Application.delete_env(:allbert_assist, Memory)
      end

      restore_env(Paths, original_paths_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "list_skills returns registry-backed readable declarations" do
    assert {:ok, response} = ListSkills.run(%{}, %{})

    assert response.status == :completed
    assert response.message =~ "v0.01-safe capabilities"
    assert response.permission_decision.decision == :allowed
    assert append_memory = Enum.find(response.skills, &(&1.name == "append-memory"))
    assert append_memory.capability_contract.validation_status == :valid
    assert append_memory.capability_contract.execution_eligible?
  end

  test "read_skill returns one skill declaration" do
    assert {:ok, response} = ReadSkill.run(%{name: "plan_shell_command"}, %{})

    assert response.status == :completed
    assert response.message =~ "Plan Shell Command"
    assert response.message =~ "command_plan"
    assert response.message =~ "Contract validation: valid"
    assert response.message =~ "Execution eligible: true"
    assert response.permission_decision.decision == :allowed

    assert [%{skill_metadata: %{capability_contract: %{validation_status: :valid}}}] =
             response.actions
  end

  test "activate_skill returns wrapped instructions without executing resources" do
    assert {:ok, response} = ActivateSkill.run(%{name: "append-memory"}, %{})

    assert response.status == :completed
    assert response.message =~ "## Skill Context"
    assert response.message =~ "Name: append-memory"
    assert response.message =~ "## v0.03 Safety Boundary"
    assert response.permission_decision.decision == :allowed
    assert response.activation.capability_contract.actions == ["append_memory"]
    assert response.activation.capability_contract.validation_status == :valid
    assert response.activation.capability_contract.execution_eligible?
    assert response.activation.resource_inventory == []

    assert [
             %{
               name: "activate_skill",
               status: :completed,
               selected_skill: "append-memory",
               skill_metadata: %{source_scope: :built_in, trust_status: :trusted}
             }
           ] = response.actions
  end

  test "activate_skill returns a structured not-found response" do
    assert {:ok, response} = ActivateSkill.run(%{name: "a-missing-skill"}, %{})

    assert response.status == :not_found
    assert response.message =~ "trusted enabled skill"
    assert response.permission_decision.decision == :allowed
    assert [%{name: "activate_skill", status: :not_found}] = response.actions
  end

  test "append_memory writes durable markdown", %{root: root} do
    assert {:ok, response} =
             AppendMemory.run(
               %{memory: "I prefer short implementation updates."},
               %{request: %{input_signal_id: "sig-123", operator_id: "local", channel: :test}}
             )

    assert response.status == :completed
    assert response.message =~ "Saved markdown memory"
    assert response.permission_decision.decision == :allowed
    assert response.memory.path =~ Path.join(root, "preferences")
    assert File.exists?(response.memory.path)

    assert [
             %{
               durable: true,
               memory_path: memory_path,
               memory_category: :preferences,
               permission_decision: %{decision: :allowed}
             }
           ] = response.actions

    assert memory_path == response.memory.path
  end

  test "append_memory stores heuristic identity memory under preferences", %{root: root} do
    assert {:ok, response} =
             AppendMemory.run(
               %{
                 memory: """
                 Heuristic family: identity.name
                 Inferred memory: Preferred name: Sandeep
                 Original statement: my name is Sandeep
                 """
               },
               %{request: %{input_signal_id: "sig-name", operator_id: "local", channel: :test}}
             )

    assert response.status == :completed
    assert response.memory.path =~ Path.join(root, "preferences")
    assert response.memory.category == :preferences
    assert response.memory.body =~ "Preferred name: Sandeep"
  end

  test "read_recent_memory returns markdown-backed entries" do
    assert {:ok, _response} =
             AppendMemory.run(
               %{memory: "My planning docs should be implementation-ready."},
               %{request: %{input_signal_id: "sig-123", operator_id: "local", channel: :test}}
             )

    assert {:ok, response} =
             ReadRecentMemory.run(
               %{query: "What do you remember about my planning docs?"},
               %{}
             )

    assert response.status == :completed
    assert response.message =~ "markdown-backed memories"
    assert [%{body: body}] = response.memories
    assert body =~ "planning docs"
  end

  test "plan_shell_command never executes requested command" do
    assert {:ok, response} =
             PlanShellCommand.run(%{command: "rm -rf /tmp/example"}, %{})

    assert response.status == :denied
    assert response.message =~ "I will not execute shell commands"
    assert response.permission_decision.decision == :denied

    assert [
             %{
               execution: :not_available,
               destructive: true,
               permission_decision: %{decision: :allowed},
               requested_permission_decision: %{decision: :denied}
             }
           ] = response.actions
  end

  test "external_network_request requires confirmation and makes no call" do
    assert {:ok, response} =
             ExternalNetworkRequest.run(%{request: "fetch https://example.com"}, %{
               actor: "local",
               channel: :test
             })

    assert response.status == :needs_confirmation
    assert response.message =~ "External network request is ready"
    assert response.permission_decision.decision == :needs_confirmation
    assert response.confirmation_id =~ "conf_"
    assert response.confirmation["origin"]["channel"] == "test"

    assert [
             %{
               execution: :pending_confirmation,
               permission: :external_network,
               permission_decision: %{decision: :needs_confirmation},
               confirmation_id: confirmation_id
             }
           ] = response.actions

    assert confirmation_id == response.confirmation_id
    assert {:ok, pending} = Confirmations.read(confirmation_id)
    assert pending["status"] == "pending"
    assert pending["target_action"]["name"] == "external_network_request"
    assert pending["target_execution_mode"] == "req_http"
  end

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/"], %{audit?: false})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
