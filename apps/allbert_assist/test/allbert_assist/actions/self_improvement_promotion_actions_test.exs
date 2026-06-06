defmodule AllbertAssist.Actions.SelfImprovementPromotionActionsTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Drafts.Store
  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Workflows

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_memory_config = Application.get_env(:allbert_assist, AllbertAssist.Memory)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-self-improvement-promotions-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, AllbertAssist.Memory, root: Path.join(root, "memory"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(AllbertAssist.Memory, original_memory_config)
      restore_env(Settings, original_settings_config)
      remove_test_root!(root)
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

    assert {:ok, template} = Registry.capability("promote_template_draft")
    assert template.permission == :dynamic_codegen_request
    assert template.execution_mode == :template_dynamic_draft
    assert template.confirmation == :not_required
    refute template.resumable?

    assert {:ok, objective} = Registry.capability("promote_objective_draft")
    assert objective.permission == :objective_write
    assert objective.execution_mode == :objective_draft_promotion
    assert objective.confirmation == :required
    assert objective.resumable?
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

    memory_path = get_in(approved.confirmation, ["operator_resolution", "target_result", "path"])
    assert is_binary(memory_path)
    assert File.regular?(memory_path)

    assert {:ok, promoted} = Store.show_draft(draft.id, kind: "memory_promotion")
    assert promoted.tier == "promoted"

    assert {:ok, memory_entry} = Memory.read_entry(memory_path)
    assert memory_entry.body == "Confirmed memory promotions write through Memory.append."
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

  test "template draft promotion creates an inert dynamic draft only" do
    enable_template_create!()
    enable_live_template_stack!()

    assert {:ok, draft} =
             Store.create_template_backed_draft(%{
               id: "template_confirmed_release_health",
               summary: "Repeated release health checks could use the LLM tool template.",
               pattern_id: "llm_tool",
               params: %{
                 "name" => "Confirmed Release Health Tool",
                 "description" => "Summarize release health evidence.",
                 "instruction" => "Return a concise release health summary.",
                 "permission" => "read_only"
               }
             })

    assert {:ok, response} = Runner.run("promote_template_draft", %{id: draft.id}, context())
    assert response.status == :completed
    assert response.dynamic_draft.template_pattern_id == "llm_tool"
    assert response.dynamic_draft.tier == "draft"
    assert response.dynamic_draft.gate_status == "not_run"
    assert response.result.target == "dynamic_template_draft"

    assert {:ok, dynamic_draft} = DynamicPlugins.get_draft(response.dynamic_draft.slug)
    assert dynamic_draft.producer == "template_pattern"
    assert dynamic_draft.gate["status"] == "not_run"

    assert {:ok, promoted} = Store.show_draft(draft.id, kind: "template_backed")
    assert promoted.tier == "promoted"
    assert promoted.live_authority == false
    assert promoted.promotion["target"] == "dynamic_template_draft"
    assert promoted.promotion["dynamic_draft_slug"] == response.dynamic_draft.slug

    assert {:ok, unified} = Store.show_draft("code:#{response.dynamic_draft.slug}")
    assert unified.kind == "code"
    assert unified.live_authority == false
  end

  test "objective draft promotion frames an objective only after confirmation" do
    assert {:ok, draft} =
             Store.create_objective_draft(%{
               id: "objective_confirmed_release_review",
               summary: "Repeated release review should become an objective.",
               title: "Review release handoff",
               objective: "Review the v0.47b release handoff before tagging.",
               acceptance_criteria: %{"docs_checked" => true},
               user_id: "operator",
               active_app: "workspace",
               source_thread_id: "thread-release"
             })

    assert {:ok, []} = AllbertAssist.Objectives.list("operator")

    assert {:ok, pending} = Runner.run("promote_objective_draft", %{id: draft.id}, context())
    assert pending.status == :needs_confirmation
    assert {:ok, []} = AllbertAssist.Objectives.list("operator")

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "fixture approval"},
               context()
             )

    assert approved.status == :completed
    assert approved.confirmation["status"] == "approved"
    assert approved.confirmation["operator_resolution"]["target_resumed?"]

    assert %{"objective_id" => objective_id} =
             approved.confirmation["operator_resolution"]["target_result"]

    assert {:ok, [objective]} = AllbertAssist.Objectives.list("operator")
    assert objective.id == objective_id
    assert objective.title == "Review release handoff"
    assert objective.source_thread_id == "thread-release"

    assert {:ok, promoted} = Store.show_draft(draft.id, kind: "objective")
    assert promoted.tier == "promoted"
    assert promoted.promotion["target"] == "objective"
    assert promoted.promotion["objective_id"] == objective_id
  end

  defp context do
    %{actor: "operator", user_id: "operator", channel: :test, surface: "test"}
  end

  defp enable_template_create! do
    assert {:ok, _setting} = Settings.put("templates.create.enabled", true, %{audit?: false})
  end

  defp enable_live_template_stack! do
    assert {:ok, _setting} = Settings.put("dynamic_codegen.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("dynamic_codegen.live_loader_enabled", true, %{audit?: false})

    assert {:ok, _setting} = Settings.put("sandbox.elixir.enabled", true, %{audit?: false})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp remove_test_root!(root, attempts \\ 3)

  defp remove_test_root!(root, 0), do: File.rm_rf!(root)

  defp remove_test_root!(root, attempts) do
    case File.rm_rf(root) do
      {:ok, _removed} ->
        :ok

      {:error, _path, _reason} ->
        Process.sleep(25)
        remove_test_root!(root, attempts - 1)
    end
  end
end
