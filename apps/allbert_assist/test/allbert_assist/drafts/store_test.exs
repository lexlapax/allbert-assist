defmodule AllbertAssist.Drafts.StoreTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Drafts.Store
  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.Marketplace
  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.Paths
  alias AllbertAssist.Workflows
  alias AllbertAssist.Workflows.Validator

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-drafts-store-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(home)
    Application.put_env(:allbert_assist, Paths, home: home)

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "lists dynamic code drafts through the unified facade", %{home: home} do
    assert {:ok, _draft} =
             DynamicPlugins.put_draft(%{
               slug: "weather_summary",
               revision: "rev_test_001",
               producer: "test",
               target_shapes: ["action"]
             })

    assert [%{id: "weather_summary", slug: "weather_summary", kind: "code", tier: "draft"}] =
             Store.list_drafts(kind: "code")

    assert {:ok, draft} = Store.show_draft("code:weather_summary")
    assert draft.root == Path.join([home, "dynamic_plugins", "drafts", "weather_summary"])
  end

  test "creates skill drafts disabled and untrusted" do
    assert {:ok, draft} =
             Store.create_skill_draft(%{
               id: "skill_release_review",
               summary: "Repeated release review prompt could become a skill.",
               source_suggestion_id: "suggestion:self_improvement:skill",
               evidence_refs: [%{path: "memory/traces/release.md"}]
             })

    assert draft.kind == "skill"
    assert draft.tier == "draft"
    assert draft.live_authority == false
    assert draft.payload["enabled"] == false
    assert draft.payload["trust_status"] == "untrusted"
    assert File.regular?(draft.artifact_path)
  end

  test "creates schema-valid workflow drafts outside the live workflow root", %{home: home} do
    assert {:ok, draft} =
             Store.create_workflow_draft(%{
               id: "workflow_release_review",
               summary: "Repeated release review prompt could become a workflow.",
               source_suggestion_id: "suggestion:self_improvement:workflow"
             })

    assert draft.kind == "workflow"
    assert draft.live_authority == false
    assert draft.payload["enabled"] == false
    assert {:ok, _workflow} = Validator.validate(draft.payload["workflow"])
    refute Workflows.exists?("workflow_release_review")

    assert draft.artifact_path ==
             Path.join([home, "drafts", "workflows", "workflow_release_review.yaml"])

    assert File.regular?(draft.artifact_path)
  end

  test "creates memory promotion drafts without writing live memory" do
    assert {:ok, draft} =
             Store.create_memory_draft(%{
               id: "memory_release_review",
               kind: "memory_promotion",
               summary: "Repeated release review memory.",
               body: "Release review memory is draft-only until confirmed."
             })

    assert draft.kind == "memory_promotion"
    assert draft.tier == "draft"
    assert draft.live_authority == false

    assert draft.payload["memory"]["body"] ==
             "Release review memory is draft-only until confirmed."

    assert File.regular?(draft.artifact_path)
  end

  test "creates capability-gap drafts as inert advisory handoff data", %{home: home} do
    assert {:ok, draft} =
             Store.create_capability_gap_draft(%{
               id: "capability_release_health",
               summary: "Repeated release health checks could become a dynamic action.",
               requested_capability: "Generate a read-only release health action.",
               target_shapes: ["action"],
               source: "self_improvement",
               confidence: 0.82,
               source_suggestion_id: "suggestion:self_improvement:capability"
             })

    assert draft.kind == "capability_gap"
    assert draft.tier == "draft"
    assert draft.live_authority == false
    assert draft.payload["enabled"] == false
    assert draft.payload["capability_gap"]["source"] == "self_improvement"
    assert draft.payload["capability_gap"]["explicit"] == false
    assert draft.payload["handoff"]["dynamic_draft_requested"] == false
    assert draft.payload["handoff"]["gate_required_before_integration"] == true
    assert File.regular?(draft.artifact_path)

    refute File.dir?(
             Path.join([
               home,
               "dynamic_plugins",
               "drafts",
               draft.payload["capability_gap"]["slug"]
             ])
           )
  end

  test "creates objective drafts as declarative data only", %{home: home} do
    assert {:ok, draft} =
             Store.create_objective_draft(%{
               id: "objective_release_review",
               summary: "Repeated release review steps could become an objective.",
               title: "Review the release checklist",
               objective: "Review the v0.47b release checklist before tagging.",
               acceptance_criteria: %{"docs_checked" => true},
               user_id: "alice",
               active_app: "workspace",
               source_suggestion_id: "suggestion:self_improvement:objective"
             })

    assert draft.kind == "objective"
    assert draft.tier == "draft"
    assert draft.live_authority == false
    assert draft.payload["enabled"] == false
    assert draft.payload["objective"]["title"] == "Review the release checklist"

    assert draft.payload["objective"]["objective"] ==
             "Review the v0.47b release checklist before tagging."

    assert draft.payload["handoff"]["objective_framed"] == false
    assert draft.payload["handoff"]["confirmation_required"] == true

    assert draft.artifact_path ==
             Path.join([home, "drafts", "objectives", "objective_release_review.objective.yaml"])

    assert File.regular?(draft.artifact_path)
  end

  test "creates template-backed drafts from reviewed template previews", %{home: home} do
    assert {:ok, draft} =
             Store.create_template_backed_draft(%{
               id: "template_release_health",
               summary: "Repeated release health checks could use the LLM tool template.",
               pattern_id: "llm_tool",
               params: %{
                 "name" => "Release Health Tool",
                 "description" => "Summarize release health evidence.",
                 "instruction" => "Return a concise release health summary.",
                 "permission" => "read_only"
               },
               source_suggestion_id: "suggestion:self_improvement:template"
             })

    assert draft.kind == "template_backed"
    assert draft.tier == "draft"
    assert draft.live_authority == false
    assert draft.payload["enabled"] == false
    assert draft.payload["template"]["pattern_id"] == "llm_tool"
    assert draft.payload["template"]["live_integration?"] == true
    assert draft.payload["template"]["target_shapes"] == ["action"]

    assert Enum.any?(
             draft.payload["template"]["preview_files"],
             &(&1["path"] == "dynamic_manifest.json")
           )

    assert draft.payload["handoff"]["create_from_template_requested"] == false
    assert draft.payload["handoff"]["gate_required_before_integration"] == true

    assert draft.artifact_path ==
             Path.join([home, "drafts", "templates", "template_release_health.template.yaml"])

    assert File.regular?(draft.artifact_path)
    refute File.dir?(Path.join([home, "dynamic_plugins", "drafts", "release_health_tool"]))
  end

  test "creates marketplace-backed drafts from catalog metadata without authority", %{home: home} do
    assert {:ok, entries} = Marketplace.list_entries()
    assert Enum.any?(entries, &(&1["id"] == "allbert/workspace-brief"))

    assert {:ok, draft} =
             Store.create_marketplace_backed_draft(%{
               id: "marketplace_workspace_brief",
               summary: "Workspace brief marketplace entry looks relevant.",
               marketplace_entry_id: "allbert/workspace-brief",
               source_suggestion_id: "suggestion:self_improvement:marketplace"
             })

    assert draft.kind == "marketplace_backed"
    assert draft.tier == "draft"
    assert draft.live_authority == false
    assert draft.payload["enabled"] == false
    assert draft.payload["marketplace"]["metadata_source"] == "Marketplace.list_entries/1"
    assert draft.payload["marketplace"]["authority"] == "metadata_only"
    assert draft.payload["marketplace"]["entry"]["id"] == "allbert/workspace-brief"
    assert draft.payload["marketplace"]["entry"]["kind"] == "template"
    assert draft.payload["handoff"]["install_requested"] == false
    assert draft.payload["handoff"]["install_status"] == "not_started"

    assert draft.artifact_path ==
             Path.join([
               home,
               "drafts",
               "marketplace",
               "marketplace_workspace_brief.marketplace.yaml"
             ])

    assert File.regular?(draft.artifact_path)
    refute File.dir?(Path.join([home, "marketplace", "installed"]))
  end

  test "creates delegate-plugin draft requests without registering an agent", %{home: home} do
    assert {:ok, draft} =
             Store.create_delegate_plugin_draft(%{
               id: "delegate_release_reviewer",
               summary: "Repeated release review could use a delegate plugin request.",
               delegate_agent_id: "release.reviewer",
               params: %{
                 "name" => "Release Reviewer",
                 "description" => "Inert delegate plugin request for release review.",
                 "version" => "0.1.0"
               },
               source_suggestion_id: "suggestion:self_improvement:delegate"
             })

    assert draft.kind == "delegate_plugin_request"
    assert draft.tier == "draft"
    assert draft.live_authority == false
    assert draft.payload["enabled"] == false
    assert draft.payload["delegate_plugin"]["delegate_agent_id"] == "release.reviewer"
    assert draft.payload["delegate_plugin"]["plugin_template_pattern_id"] == "plugin"
    assert draft.payload["delegate_plugin"]["agent_registered"] == false
    assert draft.payload["handoff"]["scaffold_requested"] == false
    assert draft.payload["handoff"]["agent_registered"] == false

    assert Enum.any?(
             draft.payload["delegate_plugin"]["preview_files"],
             &(&1["path"] == "allbert_plugin.json")
           )

    assert {:error, :not_found} = AgentRegistry.lookup("release.reviewer")
    refute File.dir?(Path.join([home, "plugins", "release_reviewer"]))

    assert draft.artifact_path ==
             Path.join([
               home,
               "drafts",
               "delegate_plugins",
               "delegate_release_reviewer.delegate_plugin.yaml"
             ])

    assert File.regular?(draft.artifact_path)
  end

  test "discard leaves non-code drafts inert and terminal" do
    assert {:ok, draft} =
             Store.create_skill_draft(%{
               id: "skill_discard_me",
               summary: "Repeated discard prompt could become a skill."
             })

    assert {:ok, discarded} = Store.discard_draft(draft.id, kind: "skill")
    assert discarded.tier == "discarded"
    assert discarded.live_authority == false
    assert discarded.payload["enabled"] == false

    assert {:error, :discarded_terminal} = Store.discard_draft(draft.id, kind: "skill")
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
