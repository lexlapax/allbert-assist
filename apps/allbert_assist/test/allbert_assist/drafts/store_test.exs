defmodule AllbertAssist.Drafts.StoreTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Drafts.Store
  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.Paths
  alias AllbertAssist.Workflows
  alias AllbertAssist.Workflows.Validator

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(System.tmp_dir!(), "allbert-drafts-store-#{System.unique_integer([:positive])}")

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
