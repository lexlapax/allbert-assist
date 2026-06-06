defmodule Mix.Tasks.Allbert.SelfImprovementTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Drafts.Store
  alias AllbertAssist.Tools.Discovery
  alias Mix.Tasks.Allbert.SelfImprovement, as: SelfImprovementTask

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-self-improvement-task-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Mix.Task.reenable("allbert.self_improvement")

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      Mix.Task.reenable("allbert.self_improvement")
      File.rm_rf!(root)
    end)

    :ok
  end

  test "list and inspect print self-improvement suggestions" do
    assert {:ok, suggestion} =
             Discovery.upsert_self_improvement_suggestion(%{
               id: "suggestion:self_improvement:cli-skill",
               suggestion_type: "trace_to_skill",
               summary: "Repeated release-plan prompt could become a skill.",
               evidence_refs: [%{path: "traces/release.md"}],
               proposed_draft_kind: "skill"
             })

    list_output =
      capture_io(fn ->
        assert :ok = SelfImprovementTask.run(["list"])
      end)

    assert list_output =~ "Self-improvement suggestions: 1"
    assert list_output =~ suggestion.id
    assert list_output =~ "trace_to_skill"
    assert list_output =~ "Repeated release-plan prompt could become a skill."

    inspect_output =
      capture_io(fn ->
        assert :ok = SelfImprovementTask.run(["inspect", suggestion.id])
      end)

    assert inspect_output =~ "id=#{suggestion.id}"
    assert inspect_output =~ "suggestion_type=trace_to_skill"
    assert inspect_output =~ "provenance=self_improvement"
    assert inspect_output =~ "proposed_draft_kind=skill"
  end

  test "draft subcommands print and discard inert drafts" do
    assert {:ok, draft} =
             Store.create_skill_draft(%{
               id: "skill_cli_review",
               summary: "Repeated CLI prompt could become a skill.",
               source_suggestion_id: "suggestion:self_improvement:cli-draft"
             })

    list_output =
      capture_io(fn ->
        assert :ok = SelfImprovementTask.run(["drafts", "list"])
      end)

    assert list_output =~ "Self-improvement drafts: 1"
    assert list_output =~ draft.id
    assert list_output =~ "skill"

    inspect_output =
      capture_io(fn ->
        assert :ok = SelfImprovementTask.run(["drafts", "inspect", draft.id])
      end)

    assert inspect_output =~ "id=#{draft.id}"
    assert inspect_output =~ "kind=skill"
    assert inspect_output =~ "live_authority=false"

    discard_output =
      capture_io(fn ->
        assert :ok = SelfImprovementTask.run(["drafts", "discard", draft.id])
      end)

    assert discard_output =~ "Discarded self-improvement draft #{draft.id}."
    assert discard_output =~ "tier=discarded"
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
