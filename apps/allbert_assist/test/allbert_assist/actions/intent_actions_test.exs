defmodule AllbertAssist.Actions.IntentActionsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Intent.ActivateSkill
  alias AllbertAssist.Actions.Intent.AppendMemory
  alias AllbertAssist.Actions.Intent.ExplainIntent
  alias AllbertAssist.Actions.Intent.ExternalNetworkRequest
  alias AllbertAssist.Actions.Intent.ListIntentCandidates
  alias AllbertAssist.Actions.Intent.ListSkills
  alias AllbertAssist.Actions.Intent.PlanShellCommand
  alias AllbertAssist.Actions.Intent.ReadRecentMemory
  alias AllbertAssist.Actions.Intent.ReadSkill
  alias AllbertAssist.Actions.Intent.UnsupportedResourceWorkflow
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
    assert response.message =~ "read-only capabilities"
    assert response.permission_decision.decision == :allowed
    assert append_memory = Enum.find(response.skills, &(&1.name == "append-memory"))
    assert append_memory.capability_contract.validation_status == :valid
    assert append_memory.capability_contract.execution_eligible?
  end

  test "explain_intent returns bounded decision metadata without execution" do
    assert {:ok, response} = ExplainIntent.run(%{text: "Open Allbert chat"}, %{})

    assert response.status == :completed
    assert response.message =~ "Intent :open_surface"
    assert response.decision.intent == :open_surface
    assert response.intent_candidates.selected.kind == :surface

    assert [%{name: "explain_intent", intent_metadata: %{candidate_count: count}}] =
             response.actions

    assert count > 0
  end

  test "list_intent_candidates returns bounded ranked candidates without execution" do
    assert {:ok, response} =
             ListIntentCandidates.run(%{text: "what can you do?"}, %{})

    assert response.status == :completed
    assert response.message =~ "Intent candidates"
    assert Enum.any?(response.candidates, &(&1.kind == :action and &1.id == "direct_answer"))

    assert [%{name: "list_intent_candidates", intent_metadata: %{candidate_count: count}}] =
             response.actions

    assert count == length(response.candidates)
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

  test "v0.65: read_recent_memory runs with no query (launch-path 'show what you remember')" do
    assert {:ok, _response} =
             AppendMemory.run(
               %{memory: "I prefer aisle seats."},
               %{request: %{input_signal_id: "sig-777", operator_id: "local", channel: :test}}
             )

    # No query param at all — the launch-path prompt "show what you remember" must run
    # (return recent memory) rather than stall on a missing required slot.
    assert {:ok, response} = ReadRecentMemory.run(%{}, %{})
    assert response.status == :completed
    assert response.message =~ "markdown-backed memories"
    assert Enum.any?(response.memories, &(&1.body =~ "aisle seats"))
  end

  test "plan_shell_command never executes requested command" do
    assert {:ok, response} =
             PlanShellCommand.run(%{command: "rm -rf /tmp/example"}, %{})

    assert response.status == :denied
    assert response.message =~ "I will not execute shell commands from this planning response."
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

  test "unsupported_resource_workflow explains deferred v0.11 resource workflows" do
    assert {:ok, response} =
             UnsupportedResourceWorkflow.run(
               %{
                 workflow: "summarize_url",
                 resource: "https://example.com/report.pdf",
                 source_text: "check this URL and summarize it"
               },
               %{actor: "local", channel: :test}
             )

    assert response.status == :unsupported
    assert response.message =~ "URL summarization is deferred to v0.11"
    assert response.message =~ "no fetch, read, extraction, summarization"
    assert response.message =~ "external_network_request"
    assert response.message =~ "Resource: https://example.com/report.pdf"
    assert response.permission_decision.decision == :allowed

    assert [
             %{
               name: "unsupported_resource_workflow",
               status: :unsupported,
               execution: :not_started,
               workflow: :summarize_url,
               v0_10_supported?: false
             }
           ] = response.actions
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
