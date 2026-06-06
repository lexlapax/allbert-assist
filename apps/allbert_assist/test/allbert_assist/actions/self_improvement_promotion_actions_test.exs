defmodule AllbertAssist.Actions.SelfImprovementPromotionActionsTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Drafts.Store
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Workflows

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-self-improvement-promotions-#{System.unique_integer([:positive])}"
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

  test "promotion actions are registered as confirmation-required internal actions" do
    assert {:ok, skill} = Registry.capability("promote_skill_draft")
    assert skill.permission == :skill_write
    assert skill.confirmation == :required
    assert skill.resumable?

    assert {:ok, workflow} = Registry.capability("promote_workflow_draft")
    assert workflow.permission == :objective_write
    assert workflow.execution_mode == :workflow_draft_promotion
    assert workflow.confirmation == :required
    assert workflow.resumable?

    assert {:ok, memory} = Registry.capability("promote_memory_draft")
    assert memory.permission == :memory_write
    assert memory.execution_mode == :memory_promotion
    assert memory.confirmation == :required
    assert memory.resumable?
  end

  test "memory draft facade writes draft state only", %{root: root} do
    assert {:ok, draft} =
             Store.create_memory_draft(%{
               id: "memory_release_note",
               kind: "memory_promotion",
               summary: "Remember the release note pattern.",
               body: "Release notes should include focused gate evidence.",
               category: "notes"
             })

    assert draft.kind == "memory_promotion"
    assert draft.live_authority == false
    assert File.regular?(draft.artifact_path)
    assert [] == Path.wildcard(Path.join([root, "memory", "notes", "*.md"]))
  end

  test "workflow draft facade writes draft state only", %{root: root} do
    assert {:ok, draft} =
             Store.create_workflow_draft(%{
               id: "workflow_release_note",
               summary: "Repeated release note workflow."
             })

    assert File.regular?(draft.artifact_path)
    refute Workflows.exists?("workflow_release_note")
    assert [] == Path.wildcard(Path.join([root, "workflows", "*.yaml"]))
  end

  test "confirmed memory draft promotion creates a live memory entry", %{root: root} do
    assert {:ok, draft} =
             Store.create_memory_draft(%{
               id: "memory_confirmed_release",
               kind: "memory_promotion",
               summary: "Remember confirmed promotion.",
               body: "Confirmed memory promotions write through Memory.append.",
               category: "notes"
             })

    assert {:ok, pending} = Runner.run("promote_memory_draft", %{id: draft.id}, context())
    assert pending.status == :needs_confirmation
    assert [] == Path.wildcard(Path.join([root, "memory", "notes", "*.md"]))

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "fixture approval"},
               context()
             )

    assert approved.status == :completed
    assert approved.confirmation["status"] == "approved"
    assert approved.confirmation["operator_resolution"]["target_resumed?"]
    assert [_path] = Path.wildcard(Path.join([root, "memory", "notes", "*.md"]))
    assert {:ok, promoted} = Store.show_draft(draft.id, kind: "memory_promotion")
    assert promoted.tier == "promoted"

    assert {:ok, [_entry]} = Memory.list_entries(category: :notes, include_body: true)
  end

  test "denied workflow draft promotion writes no live workflow", %{root: root} do
    assert {:ok, draft} =
             Store.create_workflow_draft(%{
               id: "workflow_denied_release",
               summary: "Denied release workflow promotion."
             })

    assert {:ok, pending} = Runner.run("promote_workflow_draft", %{id: draft.id}, context())
    assert pending.status == :needs_confirmation

    assert {:ok, denied} =
             Runner.run(
               "deny_confirmation",
               %{id: pending.confirmation_id, reason: "fixture denial"},
               context()
             )

    assert denied.status == :completed
    assert denied.confirmation["status"] == "denied"
    refute Workflows.exists?("workflow_denied_release")
    assert [] == Path.wildcard(Path.join([root, "workflows", "*.yaml"]))
    assert {:ok, still_draft} = Store.show_draft(draft.id, kind: "workflow")
    assert still_draft.tier == "draft"
  end

  defp context do
    %{actor: "operator", user_id: "operator", channel: :test, surface: "test"}
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
