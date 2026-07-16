defmodule AllbertAssist.Security.V047SelfImprovementEvalTest do
  use AllbertAssist.DataCase, async: false, lane: :security_eval_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Drafts.Store
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.SelfImprovement.TraceIndex
  alias AllbertAssist.Settings
  alias AllbertAssist.Tools.Discovery
  alias AllbertAssist.Workflows

  @eval_ids [
    "self-improvement-read-only-pattern-scan-001",
    "self-improvement-suggestion-no-authority-001",
    "self-improvement-draft-disabled-untrusted-001",
    "self-improvement-memory-workflow-draft-only-001",
    "self-improvement-repeated-use-no-permission-grant-001",
    "self-improvement-trace-index-redaction-001",
    "self-improvement-promotion-requires-confirmation-001"
  ]

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_memory_config = Application.get_env(:allbert_assist, Memory)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v047-self-improvement-eval-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive, :monotonic])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Memory, root: Path.join(root, "memory"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Memory, original_memory_config)
      remove_test_root!(root)
    end)

    %{root: root}
  end

  test "v0.47 eval inventory rows are complete" do
    rows = EvalInventory.rows_for_milestone(:v047)

    assert Enum.map(rows, & &1.id) == @eval_ids
    assert Enum.all?(rows, &(&1.surface == :operator_supervised_self_improvement))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
  end

  test "read-only pattern scan writes only advisory suggestions and redacts secrets", %{
    root: root
  } do
    assert_eval!("self-improvement-read-only-pattern-scan-001")
    assert_eval!("self-improvement-suggestion-no-authority-001")
    assert_eval!("self-improvement-repeated-use-no-permission-grant-001")
    assert_eval!("self-improvement-trace-index-redaction-001")

    enable_self_improvement!()

    for index <- 1..3 do
      write_trace(root, "release-review-#{index}.md", %{
        user_id: "alice",
        app_id: "workspace",
        input: "Summarize this release plan using secret://provider/api_key",
        action: "read_recent_memory"
      })
    end

    assert {:ok, %{enabled?: true, patterns: patterns}} =
             TraceIndex.index(user_id: "alice", app_id: "workspace")

    assert Enum.any?(patterns, &(&1.pattern_type == :repeated_prompt))
    refute inspect(patterns) =~ "secret://provider/api_key"

    assert {:ok, response} =
             Runner.run(
               "discover_patterns",
               %{
                 query: "what could you turn into a skill",
                 user_id: "alice",
                 app_id: "workspace"
               },
               context()
             )

    assert response.status == :completed
    assert response.permission_decision.permission == :read_only
    assert Enum.all?(response.actions, &(&1.permission == :read_only))
    assert Discovery.list_suggestions(status: "pending", provenance: "self_improvement") != []
    assert [] == Path.wildcard(Path.join([root, "skills", "*", "SKILL.md"]))
    assert [] == Path.wildcard(Path.join([root, "workflows", "*.yaml"]))
    assert [] == Path.wildcard(Path.join([root, "memory", "notes", "*.md"]))
  end

  test "skill, memory, and workflow draft facades are inert before promotion", %{root: root} do
    assert_eval!("self-improvement-draft-disabled-untrusted-001")
    assert_eval!("self-improvement-memory-workflow-draft-only-001")

    skill_suggestion =
      suggestion!("trace_to_skill", "skill", "Repeated prompt could become a skill.")

    assert {:ok, skill_response} =
             Runner.run(
               "create_self_improvement_draft",
               %{suggestion_id: skill_suggestion.id, id: "skill_eval_review"},
               context()
             )

    assert skill_response.draft.payload["enabled"] == false
    assert skill_response.draft.payload["trust_status"] == "untrusted"

    assert {:ok, memory_draft} =
             Store.create_memory_draft(%{
               id: "memory_eval_review",
               kind: "memory_promotion",
               summary: "Remember the eval review.",
               body: "Draft-only memory eval."
             })

    assert {:ok, workflow_draft} =
             Store.create_workflow_draft(%{
               id: "workflow_eval_review",
               summary: "Draft-only workflow eval."
             })

    assert memory_draft.live_authority == false
    assert workflow_draft.live_authority == false
    assert File.regular?(memory_draft.artifact_path)
    assert File.regular?(workflow_draft.artifact_path)
    assert [] == Path.wildcard(Path.join([root, "skills", "*", "SKILL.md"]))
    assert [] == Path.wildcard(Path.join([root, "memory", "notes", "*.md"]))
    refute Workflows.exists?("workflow_eval_review")
  end

  test "promotion requires confirmation and denial writes nothing", %{root: root} do
    assert_eval!("self-improvement-promotion-requires-confirmation-001")

    assert {:ok, memory_draft} =
             Store.create_memory_draft(%{
               id: "memory_eval_confirmed",
               kind: "memory_promotion",
               summary: "Confirmed memory eval.",
               body: "Confirmed promotion writes through memory."
             })

    assert {:ok, workflow_draft} =
             Store.create_workflow_draft(%{
               id: "workflow_eval_denied",
               summary: "Denied workflow eval."
             })

    assert {:ok, pending_memory} =
             Runner.run("promote_memory_draft", %{id: memory_draft.id}, context())

    assert pending_memory.status == :needs_confirmation
    assert [] == Path.wildcard(Path.join([root, "memory", "notes", "*.md"]))

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending_memory.confirmation_id, reason: "eval approval"},
               context()
             )

    assert approved.status == :completed
    assert approved.confirmation["operator_resolution"]["target_resumed?"]
    assert [_memory] = Path.wildcard(Path.join([root, "memory", "notes", "*.md"]))

    assert {:ok, pending_workflow} =
             Runner.run("promote_workflow_draft", %{id: workflow_draft.id}, context())

    assert pending_workflow.status == :needs_confirmation

    assert {:ok, denied} =
             Runner.run(
               "deny_confirmation",
               %{id: pending_workflow.confirmation_id, reason: "eval denial"},
               context()
             )

    assert denied.status == :completed
    assert denied.confirmation["status"] == "denied"
    refute Workflows.exists?("workflow_eval_denied")
    assert {:ok, draft} = Store.show_draft(workflow_draft.id, kind: "workflow")
    assert draft.tier == "draft"
  end

  defp enable_self_improvement! do
    assert {:ok, _setting} = Settings.put("self_improvement.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("self_improvement.trace_index.enabled", true, %{audit?: false})
  end

  defp suggestion!(type, kind, summary) do
    assert {:ok, suggestion} =
             Discovery.upsert_self_improvement_suggestion(%{
               id: "suggestion:self_improvement:#{kind}:#{System.unique_integer([:positive])}",
               suggestion_type: type,
               summary: summary,
               evidence_refs: [%{path: "memory/traces/eval.md"}],
               proposed_draft_kind: kind
             })

    Discovery.suggestion_to_map(suggestion)
  end

  defp write_trace(root, name, attrs) do
    trace_root = Path.join([root, "memory", "traces"])
    File.mkdir_p!(trace_root)

    File.write!(Path.join(trace_root, name), """
    ## Runtime Turn

    - Trace format: v0.01-m6
    - Channel: test
    - User: #{attrs.user_id}
    - Active app: #{attrs.app_id}
    - Status: ok
    - Selected action: #{attrs.action}

    ## Input

    #{attrs.input}

    ## Actions

    ```elixir
    [%{name: "#{attrs.action}"}]
    ```
    """)
  end

  defp context do
    %{actor: "alice", user_id: "alice", channel: :test, surface: "v047_eval"}
  end

  defp assert_eval!(id), do: EvalInventory.row!(id)

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
