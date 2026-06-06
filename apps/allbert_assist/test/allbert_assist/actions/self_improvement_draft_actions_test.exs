defmodule AllbertAssist.Actions.SelfImprovementDraftActionsTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Drafts.Store
  alias AllbertAssist.Objectives
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Tools.Discovery
  alias AllbertAssist.Workflows
  alias AllbertAssist.Workflows.Validator

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-self-improvement-draft-actions-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "draft actions are registered with dynamic draft permissions" do
    assert {:ok, create} = Registry.capability("create_self_improvement_draft")
    assert create.permission == :dynamic_codegen_request
    assert create.exposure == :internal
    assert create.confirmation == :not_required

    assert {:ok, discard} = Registry.capability("discard_self_improvement_draft")
    assert discard.permission == :dynamic_codegen_discard
    assert discard.exposure == :internal
    assert discard.confirmation == :not_required
  end

  test "create_self_improvement_draft creates disabled untrusted skill draft" do
    suggestion =
      suggestion!("trace_to_skill", "skill", "Repeated release prompt could become a skill.")

    assert {:ok, response} =
             Runner.run(
               "create_self_improvement_draft",
               %{suggestion_id: suggestion.id, id: "skill_release_review"},
               %{actor: "operator", user_id: "operator", channel: :test}
             )

    assert response.status == :completed
    assert response.permission_decision.permission == :dynamic_codegen_request
    assert response.draft.kind == "skill"
    assert response.draft.payload["enabled"] == false
    assert response.draft.payload["trust_status"] == "untrusted"

    assert {:ok, accepted} = Discovery.get_suggestion(suggestion.id)
    assert accepted.status == "accepted"
    assert accepted.draft_id == "skill_release_review"
  end

  test "create_self_improvement_draft creates schema-valid non-live workflow draft" do
    suggestion =
      suggestion!(
        "trace_to_workflow",
        "workflow",
        "Repeated release prompt could become a workflow."
      )

    assert {:ok, response} =
             Runner.run(
               "create_self_improvement_draft",
               %{suggestion_id: suggestion.id, id: "workflow_release_review"},
               %{actor: "operator", user_id: "operator", channel: :test}
             )

    assert response.status == :completed
    assert response.draft.kind == "workflow"
    assert response.draft.live_authority == false
    assert {:ok, _workflow} = Validator.validate(response.draft.payload["workflow"])
    refute Workflows.exists?("workflow_release_review")
  end

  test "create_self_improvement_draft creates inert capability-gap and objective handoff drafts" do
    capability_suggestion =
      suggestion!(
        "capability_gap",
        "capability_gap",
        "Repeated release health checks could become a capability gap.",
        %{
          "requested_capability" => "Generate a read-only release health action.",
          "target_shapes" => ["action"],
          "source" => "self_improvement",
          "confidence" => 0.76
        }
      )

    objective_suggestion =
      suggestion!(
        "objective",
        "objective",
        "Repeated release review steps could become an objective draft.",
        %{
          "title" => "Review the release checklist",
          "objective" => "Review the v0.47b release checklist before tagging.",
          "acceptance_criteria" => %{"docs_checked" => true},
          "user_id" => "operator",
          "active_app" => "workspace"
        }
      )

    assert {:ok, capability_response} =
             Runner.run(
               "create_self_improvement_draft",
               %{suggestion_id: capability_suggestion.id, id: "capability_release_health"},
               %{actor: "operator", user_id: "operator", channel: :test}
             )

    assert {:ok, objective_response} =
             Runner.run(
               "create_self_improvement_draft",
               %{suggestion_id: objective_suggestion.id, id: "objective_release_review"},
               %{actor: "operator", user_id: "operator", channel: :test}
             )

    assert capability_response.status == :completed
    assert capability_response.draft.kind == "capability_gap"
    assert capability_response.draft.live_authority == false
    assert capability_response.draft.payload["capability_gap"]["explicit"] == false
    assert capability_response.draft.payload["handoff"]["dynamic_draft_requested"] == false

    assert objective_response.status == :completed
    assert objective_response.draft.kind == "objective"
    assert objective_response.draft.live_authority == false
    assert objective_response.draft.payload["handoff"]["objective_framed"] == false
    assert {:ok, []} = Objectives.list("operator")
  end

  test "create_self_improvement_draft returns existing accepted draft" do
    suggestion =
      suggestion!("trace_to_skill", "skill", "Repeated accepted prompt could become a skill.")

    assert {:ok, first_response} =
             Runner.run(
               "create_self_improvement_draft",
               %{suggestion_id: suggestion.id, id: "skill_existing_review"},
               %{actor: "operator", user_id: "operator", channel: :test}
             )

    assert {:ok, second_response} =
             Runner.run(
               "create_self_improvement_draft",
               %{suggestion_id: suggestion.id, id: "skill_should_not_be_created"},
               %{actor: "operator", user_id: "operator", channel: :test}
             )

    assert first_response.draft.id == "skill_existing_review"
    assert second_response.draft.id == "skill_existing_review"
    refute Enum.any?(Store.list_drafts(kind: "skill"), &(&1.id == "skill_should_not_be_created"))
  end

  test "discard_self_improvement_draft leaves no enabled capability" do
    suggestion =
      suggestion!("trace_to_skill", "skill", "Repeated discard prompt could become a skill.")

    assert {:ok, create_response} =
             Runner.run(
               "create_self_improvement_draft",
               %{suggestion_id: suggestion.id, id: "skill_discard_review"},
               %{actor: "operator", user_id: "operator", channel: :test}
             )

    assert {:ok, discard_response} =
             Runner.run(
               "discard_self_improvement_draft",
               %{id: create_response.draft.id, kind: "skill"},
               %{actor: "operator", user_id: "operator", channel: :test}
             )

    assert discard_response.status == :completed
    assert discard_response.draft.tier == "discarded"
    assert discard_response.draft.live_authority == false
    assert discard_response.draft.payload["enabled"] == false
    assert {:ok, discarded} = Store.show_draft(create_response.draft.id, kind: "skill")
    assert discarded.tier == "discarded"
  end

  defp suggestion!(type, kind, summary, metadata \\ %{}) do
    assert {:ok, suggestion} =
             Discovery.upsert_self_improvement_suggestion(%{
               id: "suggestion:self_improvement:#{kind}:#{System.unique_integer([:positive])}",
               suggestion_type: type,
               summary: summary,
               evidence_refs: [%{path: "memory/traces/release.md"}],
               proposed_draft_kind: kind,
               metadata: metadata
             })

    Discovery.suggestion_to_map(suggestion)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
