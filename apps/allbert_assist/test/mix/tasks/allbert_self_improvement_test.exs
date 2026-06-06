defmodule Mix.Tasks.Allbert.SelfImprovementTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
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

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
