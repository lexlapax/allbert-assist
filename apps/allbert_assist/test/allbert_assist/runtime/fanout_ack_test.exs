defmodule AllbertAssist.Runtime.FanoutAckTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Conversations
  alias AllbertAssist.Intent.Decomposer
  alias AllbertAssist.Intent.FanoutManager
  alias AllbertAssist.Intent.FanoutPlan
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.Fanout.TerminalTransitions
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Objectives.Runs.Scheduler
  alias AllbertAssist.Objectives.Runs.Supervisor, as: RunsSupervisor
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias Ecto.Adapters.SQL.Sandbox
  alias Jido.Signal.Bus

  defmodule SingleTurnProposer do
    def propose(text, context) do
      send(context.test_pid, {:decomposition_model_consulted, text})
      {:ok, []}
    end
  end

  defmodule VerticalManagerModel do
    @children [
      %{
        title: "Investigate Project Juniper",
        objective: "Investigate Project Juniper retry behavior.",
        expected_result: "A factual Juniper retry summary."
      },
      %{
        title: "Investigate Project Cedar",
        objective: "Investigate Project Cedar cancellation behavior.",
        expected_result: "A factual Cedar cancellation summary."
      }
    ]

    def respond(_text, _profile, %{fanout_manager_attempt: :initial}) do
      {:ok,
       %{
         "answer" => "I can investigate both projects and report the findings.",
         "outer_request_task_count" => 2,
         "request_ownership" => "no_embedded_content",
         "all_advisory_or_read_only" => true,
         "children_self_contained" => true,
         "can_progress_concurrently" => true,
         "child_result_dependency" => false,
         "full_coverage_exactly_once" => true,
         "material_parallel_leverage" => true,
         "join_role" => "parent_presentation_only",
         "children" => @children
       }}
    end

    def respond(_text, _profile, _context), do: {:error, :unexpected_manager_phase}
  end

  setup do
    original = Application.get_env(:allbert_assist, Runtime)
    test_pid = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(test_pid, {:single_turn_agent_called, request.text})
        {:ok, %{message: "single: #{request.text}", status: :completed}}
      end,
      decomposer: fn text, context ->
        context =
          context
          |> Map.put(:model_proposer, SingleTurnProposer)
          |> Map.put(:test_pid, test_pid)

        Decomposer.propose(text, context)
      end
    )

    assert {:ok, _setting} =
             Settings.put("objectives.fanout.confirm_before_start", false, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.telegram.autonomous_notify.enabled", false, %{audit?: false})

    on_exit(fn ->
      if Process.whereis(Scheduler) do
        Objective
        |> where([objective], objective.fanout_role == "parent")
        |> select([objective], objective.id)
        |> Repo.all()
        |> Enum.each(&Scheduler.finish_fanout/1)
      end

      if Process.whereis(RunsSupervisor) do
        RunsSupervisor
        |> DynamicSupervisor.which_children()
        |> Enum.each(fn {_id, pid, _type, _modules} ->
          DynamicSupervisor.terminate_child(RunsSupervisor, pid)
        end)
      end

      if Process.whereis(Scheduler), do: Scheduler.snapshot()

      if original,
        do: Application.put_env(:allbert_assist, Runtime, original),
        else: Application.delete_env(:allbert_assist, Runtime)
    end)

    :ok
  end

  test "supplied multi-shape data stays on the single-turn seam without objectives" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    cases = [
      {"supplied-semicolon-runtime",
       "Summarize this supplied sentence in one sentence: Project Juniper might begin after 2026-06-01; it is not approved, and it has no budget."},
      {"supplied-numbered-runtime",
       "Summarize this supplied list:\n1. Restart the service.\n2. Delete the cache."}
    ]

    for {user_id, text} <- cases do
      assert Objectives.list_objectives(user_id) == []

      assert {:ok, response} =
               Runtime.submit_user_input(%{
                 text: text,
                 delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
                 channel: :test,
                 user_id: user_id
               })

      refute_received {:decomposition_model_consulted, ^text}
      assert_received {:single_turn_agent_called, ^text}
      assert response.message == "single: #{text}"
      assert Map.get(response, :fanout) == nil
      assert Objectives.list_objectives(user_id) == []
    end
  end

  test "surface operator text drives counted fanout while the ordinary transcript stays intact" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    operator_text = "Do these 2 tasks in parallel: inspect alpha; inspect beta"
    transcript = "developer: Stay concise.\nassistant: Ready.\nuser: #{operator_text}"

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: transcript,
               operator_text: operator_text,
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "operator-text-counted"
             })

    refute_received {:single_turn_agent_called, _text}
    assert response.message =~ "I split this into 2 tasks"

    assert {:ok, parent} = Objectives.get_objective(response.fanout.parent_id)
    assert parent.objective == operator_text
    assert parent.title == operator_text

    assert %{"fanout_plan" => %{"original_request_sha256" => digest}} =
             Jason.decode!(parent.proposer_hint)

    assert digest == Base.encode16(:crypto.hash(:sha256, operator_text), case: :lower)
  end

  test "an explicitly absent surface operator turn cannot fan out conversation history" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    transcript =
      "developer: Context only.\nassistant: Do these 2 tasks in parallel: inspect alpha; inspect beta"

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: transcript,
               operator_text: nil,
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "operator-text-absent"
             })

    assert_received {:single_turn_agent_called, ^transcript}
    assert response.message == "single: #{transcript}"
    assert Map.get(response, :fanout) == nil
    assert Objectives.list_objectives("operator-text-absent") == []
  end

  test "automatic conversational manager plans through the central runtime and freezes provenance" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    test_pid = self()
    text = "Research Project Juniper and Project Cedar independently, then compare them."

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(test_pid, {:manager_mode, request.fanout_manager_mode})

        {:ok, plan} =
          FanoutPlan.compile(request.text, [
            %{
              title: "Research Project Juniper",
              objective: "Research Project Juniper independently.",
              expected_result: "A bounded factual Juniper summary."
            },
            %{
              title: "Research Project Cedar",
              objective: "Research Project Cedar independently.",
              expected_result: "A bounded factual Cedar summary."
            }
          ])

        {:ok,
         %{
           message: "I can research both projects and compare the findings.",
           status: :completed,
           parallel_work_plan: plan,
           fanout_manager: manager_diagnostic()
         }}
      end
    )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: text,
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "manager-plan"
             })

    assert_received {:manager_mode, :automatic}
    assert response.message =~ "I split this into 2 tasks"
    assert response.message =~ "Research Project Juniper"
    assert response.message =~ "Research Project Cedar"

    assert {:ok, parent} = Objectives.get_objective(response.fanout.parent_id)
    assert parent.source_intent == nil

    assert %{
             "fanout_plan" => %{
               "original_request_sha256" => digest,
               "plan_sha256" => plan_digest,
               "manager_profile" => "direct_answer_local",
               "manager_profile_sha256" => profile_digest,
               "manager_attempts" => 1,
               "budget" => budget,
               "source" => "conversation_manager",
               "version" => 1,
               "deadline_unix_ms" => deadline
             }
           } = Jason.decode!(parent.proposer_hint)

    assert digest == Base.encode16(:crypto.hash(:sha256, text), case: :lower)
    assert plan_digest =~ ~r/^[0-9a-f]{64}$/
    assert profile_digest =~ ~r/^[0-9a-f]{64}$/
    assert budget["manager_attempts"] == 1
    assert budget["child_count"] == 2
    assert budget["configured_output_tokens"] == 24_000
    assert budget["required_output_tokens"] == 6_144
    assert deadline > System.system_time(:millisecond)

    assert {:ok, %{max_calls: 1, max_output_tokens: 1_024}} =
             Budget.authorize_composer(budget, deadline, System.system_time(:millisecond))

    assert [%{payload: proposed_payload}] =
             Objectives.list_events(parent.id)
             |> Enum.filter(&(&1.kind == "fanout_proposed"))

    proposed_payload = Jason.decode!(proposed_payload)
    assert proposed_payload["plan_version"] == 1
    assert proposed_payload["plan_source"] == "conversation_manager"
    assert proposed_payload["original_request_sha256"] == digest
    assert proposed_payload["plan_sha256"] == plan_digest
    assert proposed_payload["budget"] == budget

    assert Enum.map(Fanout.children(parent), fn child ->
             {child.title, Jason.decode!(child.acceptance_criteria)}
           end) == [
             {"Research Project Juniper", %{"summary" => "A bounded factual Juniper summary."}},
             {"Research Project Cedar", %{"summary" => "A bounded factual Cedar summary."}}
           ]
  end

  test "invalid exact-counted protocol cannot fall through to automatic manager planning" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    test_pid = self()
    text = "Do these three tasks in parallel: inspect alpha; inspect beta"

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(test_pid, {:manager_mode, request.fanout_manager_mode})

        {:ok, plan} =
          FanoutPlan.compile(request.text, [
            %{title: "Alpha", objective: "Inspect alpha", expected_result: "Alpha result"},
            %{title: "Beta", objective: "Inspect beta", expected_result: "Beta result"}
          ])

        {:ok,
         %{
           message: "ordinary single-turn handling",
           status: :completed,
           parallel_work_plan: plan,
           fanout_manager: manager_diagnostic()
         }}
      end
    )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: text,
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "invalid-counted-manager-bypass"
             })

    assert_received {:manager_mode, :off}
    assert response.message == "ordinary single-turn handling"
    refute Map.has_key?(response, :fanout)
    assert Objectives.list_objectives("invalid-counted-manager-bypass") == []
  end

  test "compiler-invalid counted overflow neither consults the manager nor writes objectives" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    test_pid = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(test_pid, {:manager_mode, request.fanout_manager_mode})
        {:ok, %{message: "ordinary bounded response", status: :completed}}
      end
    )

    oversized = String.duplicate("x", 2_001)

    cases = [
      {"counted-overflow-duplicate",
       "Do these 9 tasks in parallel: one; two; three; four; five; six; seven; eight; ONE"},
      {"counted-overflow-oversized",
       "Do these 9 tasks in parallel: #{oversized}; two; three; four; five; six; seven; eight; nine"}
    ]

    for {user_id, text} <- cases do
      assert {:ok, response} =
               Runtime.submit_user_input(%{
                 text: text,
                 delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
                 channel: :test,
                 user_id: user_id
               })

      assert_received {:manager_mode, :off}
      assert response.message == "ordinary bounded response"
      refute Map.has_key?(response, :fanout)
      refute Map.has_key?(response, :decomposition_overflow)
      assert Objectives.list_objectives(user_id) == []
    end
  end

  test "actual Runtime IntentAgent DirectAnswer manager path frames one central durable plan" do
    original_manager = Application.get_env(:allbert_assist, FanoutManager)

    on_exit(fn ->
      if original_manager,
        do: Application.put_env(:allbert_assist, FanoutManager, original_manager),
        else: Application.delete_env(:allbert_assist, FanoutManager)
    end)

    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    Application.put_env(:allbert_assist, Runtime, decomposer: fn _text, _context -> :single end)

    Application.put_env(:allbert_assist, FanoutManager, model_client: VerticalManagerModel)

    text =
      "Investigate Project Juniper retry behavior and Project Cedar cancellation behavior, and report both findings."

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: text,
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "vertical-manager"
             })

    assert response.message =~ "I split this into 2 tasks"
    assert {:ok, parent} = Objectives.get_objective(response.fanout.parent_id)
    assert parent.objective == text
    assert parent.source_intent == nil

    assert Enum.map(Fanout.children(parent), & &1.objective) == [
             "Investigate Project Juniper retry behavior.",
             "Investigate Project Cedar cancellation behavior."
           ]

    assert %{
             "fanout_plan" => %{
               "source" => "conversation_manager",
               "manager_attempts" => 1,
               "manager_profile" => profile,
               "budget" => %{"child_count" => 2}
             }
           } = Jason.decode!(parent.proposer_hint)

    assert is_binary(profile)
  end

  test "manager framing keeps one canonical request across old projection and objective boundaries" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        {:ok, plan} =
          FanoutPlan.compile(request.text, [
            %{title: "First", objective: "Research first", expected_result: "First result"},
            %{title: "Second", objective: "Research second", expected_result: "Second result"}
          ])

        {:ok,
         %{
           message: "Safe same-call answer.",
           status: :completed,
           parallel_work_plan: plan,
           fanout_manager: manager_diagnostic()
         }}
      end
    )

    requests = [
      String.duplicate("a", 500),
      String.duplicate("b", 501),
      String.duplicate("c", 2_000),
      String.duplicate("d", 2_001),
      String.duplicate("🦉", 1_000)
    ]

    for {text, index} <- Enum.with_index(requests) do
      assert byte_size(text) <= 4_000

      assert {:ok, response} =
               Runtime.submit_user_input(%{
                 text: text,
                 delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
                 channel: :test,
                 user_id: "canonical-request-#{index}"
               })

      assert {:ok, parent} = Objectives.get_objective(response.fanout.parent_id)
      assert parent.objective == text
      assert parent.source_intent == nil

      assert get_in(Jason.decode!(parent.proposer_hint), [
               "fanout_plan",
               "original_request_sha256"
             ]) == Base.encode16(:crypto.hash(:sha256, text), case: :lower)
    end
  end

  test "validated manager plan framing failure preserves the same-call answer and writes nothing" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    text = "Research Project Juniper and Cedar independently."

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        {:ok, plan} =
          FanoutPlan.compile(request.text, [
            %{title: "Juniper", objective: "Research Juniper", expected_result: "Facts"},
            %{title: "Cedar", objective: "Research Cedar", expected_result: "Facts"}
          ])

        {:ok,
         %{
           message: "I can answer safely without parallel work.",
           status: :completed,
           parallel_work_plan: plan,
           fanout_manager: manager_diagnostic()
         }}
      end,
      fanout_framer: fn _attrs, _children -> {:error, :fixture_frame_failure} end
    )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: text,
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "frame-fallback"
             })

    assert response.message == "I can answer safely without parallel work."
    refute Map.has_key?(response, :fanout)
    assert Objectives.list_objectives("frame-fallback") == []

    assert Enum.any?(response.diagnostics, fn diagnostic ->
             diagnostic.source == :fanout_admission and
               diagnostic.outcome == :single_turn_fallback
           end)
  end

  test "manager overflow uses the central complete-list clarification and frames nothing" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    tasks = ["Research one", "Research two", "Research three"]

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, _request ->
        {:ok,
         %{
           message: "I found three tasks.",
           status: :completed,
           parallel_work_clarification: %{
             task_count: 3,
             max_children: 2,
             tasks: tasks
           }
         }}
      end
    )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Research three independent topics.",
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "manager-overflow"
             })

    assert response.message =~ "I found 3 separate tasks"
    assert response.decomposition_overflow.tasks == tasks
    assert Objectives.list_objectives("manager-overflow") == []
  end

  test "shadow manager plans are advisory and cannot create durable work" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "shadow", %{audit?: false})

    test_pid = self()
    text = "Research two independent options and compare them."

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(test_pid, {:manager_mode, request.fanout_manager_mode})

        {:ok, plan} =
          FanoutPlan.compile(request.text, [
            %{title: "Option one", objective: "Research option one", expected_result: "One"},
            %{title: "Option two", objective: "Research option two", expected_result: "Two"}
          ])

        {:ok,
         %{
           message: "One-turn fallback answer",
           status: :completed,
           parallel_work_plan: plan
         }}
      end
    )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: text,
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "manager-shadow"
             })

    assert_received {:manager_mode, :shadow}
    assert response.message == "One-turn fallback answer"
    refute Map.has_key?(response, :fanout)
    assert Objectives.list_objectives("manager-shadow") == []
  end

  test "shadow rollout keeps the exact-counted offline protocol out of the manager" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "shadow", %{audit?: false})

    test_pid = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(test_pid, {:manager_mode, request.fanout_manager_mode})
        {:ok, %{message: "ordinary shadow response", status: :completed}}
      end
    )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Do these two tasks in parallel: inspect alpha; inspect beta",
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "counted-shadow"
             })

    assert_received {:manager_mode, :off}
    assert response.message == "ordinary shadow response"
    refute Map.has_key?(response, :fanout)
    assert Objectives.list_objectives("counted-shadow") == []
  end

  test "Runtime rejects a manager plan bound to a different operator request" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    test_pid = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(test_pid, {:manager_mode, request.fanout_manager_mode})

        {:ok, plan} =
          FanoutPlan.compile("Different operator request", [
            %{title: "One", objective: "Do one", expected_result: "One result"},
            %{title: "Two", objective: "Do two", expected_result: "Two results"}
          ])

        {:ok,
         %{
           message: "Safe one-turn fallback",
           status: :completed,
           parallel_work_plan: plan
         }}
      end
    )

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Research two independent options and compare them.",
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "binding-mismatch"
             })

    assert_received {:manager_mode, :automatic}
    assert response.message == "Safe one-turn fallback"
    refute Map.has_key?(response, :fanout)
    assert Objectives.list_objectives("binding-mismatch") == []
  end

  test "an active parent refuses nested fanout before the manager can run" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    test_pid = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(test_pid, {:manager_mode, request.fanout_manager_mode})
        {:ok, %{message: "single nested response", status: :completed}}
      end
    )

    assert {:ok, first_turn} =
             Runtime.submit_user_input(%{
               text: "hello",
               channel: :test,
               user_id: "nested-owner"
             })

    assert_received {:manager_mode, :off}

    assert {:ok, %{parent: parent}} =
             Fanout.frame(
               %{
                 user_id: "nested-owner",
                 title: "Active parent",
                 objective: "Active parent",
                 source_channel: "test",
                 source_thread_id: first_turn.thread_id
               },
               ["one", "two"]
             )

    assert Fanout.parent_projection(parent).phase == :awaiting_kickoff

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Do these two tasks in parallel: nested one; nested two",
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "nested-owner",
               thread_id: first_turn.thread_id
             })

    assert_received {:manager_mode, :off}
    assert response.message == "single nested response"
    refute Map.has_key?(response, :fanout)

    assert Enum.count(Objectives.list_objectives("nested-owner"), &(&1.fanout_role == "parent")) ==
             1
  end

  test "visible kickoff is a hard start barrier and acknowledgement is idempotent" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Do these two tasks in parallel: Research alpha; draft beta",
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "alice"
             })

    assert response.message =~ "1. Research alpha"
    assert response.message =~ "2. draft beta"
    assert response.fanout.delivery_state == "pending"
    assert is_binary(response.fanout_start_receipt)

    children = Fanout.children(response.fanout.parent_id)
    assert Enum.all?(children, &(&1.run_attempt_count == 0 and &1.status == "open"))

    identity = %{user_id: "alice", channel: "test", thread_id: response.thread_id}
    assert :ok = Runtime.acknowledge_fanout_start(response.fanout_start_receipt, identity)
    assert :ok = Runtime.acknowledge_fanout_start(response.fanout_start_receipt, identity)

    terminal_children = await_fanout_terminal(response.fanout.parent_id)

    assert Enum.all?(
             terminal_children,
             &(&1.run_attempt_count >= 1 and &1.status != "running")
           )

    assert Enum.map(Fanout.children(response.fanout.parent_id), &{&1.status, &1.review_reason}) ==
             [{"completed", nil}, {"completed", nil}]
  end

  test "exact kickoff receipt lookup is not starved by newer objective rows" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Do these two tasks in parallel: first task; second task",
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "receipt-owner"
             })

    for index <- 1..75 do
      assert {:ok, _objective} =
               Objectives.create_objective(%{
                 user_id: "receipt-owner",
                 title: "newer objective #{index}",
                 objective: "newer objective #{index}"
               })
    end

    identity = %{user_id: "receipt-owner", channel: "test", thread_id: response.thread_id}
    assert :ok = Runtime.acknowledge_fanout_start(response.fanout_start_receipt, identity)

    assert Enum.all?(
             await_fanout_terminal(response.fanout.parent_id),
             &(&1.status == "completed")
           )
  end

  test "kickoff acknowledgement after an authoritative join is a no-op" do
    assert {:ok, %{parent: parent, children: children, fanout_start_receipt: receipt}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "Already joined",
                 objective: "Do not restart",
                 source_channel: "test",
                 source_thread_id: "joined-thread"
               },
               ["one", "two"]
             )

    context = %{user_id: "alice", channel: "test", thread_id: "joined-thread"}
    assert :ok = Fanout.acknowledge_start(receipt, context)

    Enum.each(children, fn child ->
      assert {:ok, _transition} =
               TerminalTransitions.terminalize_child(
                 child,
                 %{
                   status: "completed",
                   last_observation_summary: "done",
                   completed_at: DateTime.utc_now()
                 },
                 "run_completed",
                 %{}
               )
    end)

    select_queued_report!(parent.id)

    assert Fanout.parent_projection(parent).phase == :joined
    attempts_before = Enum.map(Fanout.children(parent), & &1.run_attempt_count)
    assert :ok = Runtime.acknowledge_fanout_start(receipt, context)
    assert Enum.map(Fanout.children(parent), & &1.run_attempt_count) == attempts_before
    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "kickoff copy tells attached surfaces that the final report will arrive in place" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    for channel <- [:tui, :live_view] do
      assert {:ok, response} =
               Runtime.submit_user_input(%{
                 text: "Do these two tasks in parallel: first task; second task",
                 channel: channel,
                 user_id: "attached-#{channel}",
                 delivery_ack_capability: Runtime.fanout_delivery_ack_capability()
               })

      assert response.message =~ "I'll show the final report here as soon as it is ready."
      refute response.message =~ "I'll report when you next message"
      refute Map.has_key?(response, :notify_offer)
    end
  end

  test "kickoff copy keeps next-turn and opt-in guidance for detached channels" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Do these two tasks in parallel: first task; second task",
               channel: :telegram,
               user_id: "detached",
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability()
             })

    assert response.message =~ "I'll report when you next message"
    assert response.message =~ "enable autonomous notifications"
  end

  test "kickoff copy promises push delivery when a remote channel is already authorized" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.telegram.autonomous_notify.enabled", true, %{audit?: false})

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Do these two tasks in parallel: first task; second task",
               channel: :telegram,
               user_id: "authorized-remote",
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability()
             })

    assert response.message =~ "Status and the final report will be pushed here."
    refute response.message =~ "enable autonomous notifications"
  end

  test "one-shot CLI kickoff does not promise an unattended in-place report" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("objectives.fanout.confirm_before_start", true, %{audit?: false})

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Do these two tasks in parallel: first task; second task",
               channel: :cli,
               user_id: "one-shot-cli",
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability()
             })

    assert response.message =~ "I'll report when you next message"
    refute response.message =~ "as soon as it is ready"
    refute Map.has_key?(response, :notify_offer)

    assert :ok = Runtime.acknowledge_deliveries(response, %{channel: :cli})

    assert {:ok, %{kickoff_delivery_state: "acknowledged", source_channel: "cli"}} =
             Objectives.get_objective(response.fanout.parent_id)
  end

  test "an undelivered kickoff stays pending and retry reuses its receipt" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    request = %{
      text: "Do these two tasks in parallel: first task; second task",
      channel: :test,
      user_id: "alice",
      delivery_ack_capability: Runtime.fanout_delivery_ack_capability()
    }

    assert {:ok, response} = Runtime.submit_user_input(request)

    assert {:ok, parent} = Objectives.get_objective(response.fanout.parent_id)
    assert parent.kickoff_delivery_state == "pending"
    assert Enum.all?(Fanout.children(parent), &(&1.run_attempt_count == 0))
    assert Fanout.receipt_for(:start, parent.id) == response.fanout_start_receipt

    context = %{user_id: "alice", thread_id: response.thread_id, channel: "test"}
    assert :ok = Runtime.delivery_failed(response, context)
    assert {:ok, blocked} = Objectives.get_objective(parent.id)
    assert blocked.kickoff_delivery_state == "blocked"
    assert Enum.all?(Fanout.children(parent), &(&1.run_attempt_count == 0))

    assert :ok = Runtime.acknowledge_fanout_start(response.fanout_start_receipt, context)
    assert {:ok, acknowledged} = Objectives.get_objective(parent.id)
    assert acknowledged.kickoff_delivery_state == "acknowledged"

    assert Enum.all?(await_fanout_terminal(parent.id), &(&1.status == "completed"))
  end

  test "pending reports are non-destructive and identity-bound until delivery acknowledgement" do
    assert {:ok, first_turn} =
             Runtime.submit_user_input(%{text: "hello", channel: :test, user_id: "alice"})

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "Finished work",
                 objective: "Finished work",
                 source_channel: "test",
                 source_surface: "channel",
                 source_thread_id: first_turn.thread_id
               },
               ["one", "two"]
             )

    for child <- children do
      assert {:ok, %{child: %{status: "completed"}}} =
               TerminalTransitions.terminalize_child(
                 child,
                 %{
                   status: "completed",
                   last_observation_summary: "done #{child.queue_position}",
                   completed_at: DateTime.utc_now()
                 },
                 "run_completed",
                 %{}
               )
    end

    select_queued_report!(parent.id)
    assert {:ok, %{report_delivery_receipt: receipt}} = Fanout.finalize_join(parent)
    parent_id = parent.id

    assert {:ok, next_turn} =
             Runtime.submit_user_input(%{
               text: "what next?",
               channel: :test,
               user_id: "alice",
               thread_id: first_turn.thread_id
             })

    assert [%{parent_objective_id: ^parent_id, report_delivery_receipt: ^receipt}] =
             next_turn.pending_reports

    expected_report = Fanout.format_report(Fanout.report(parent))
    assert next_turn.message == "single: what next?\n\n#{expected_report}"

    assert {:error, :receipt_identity_mismatch} =
             Runtime.acknowledge_report_delivery(receipt, %{
               user_id: "mallory",
               channel: "test",
               thread_id: first_turn.thread_id
             })

    assert [%{report_delivery_receipt: ^receipt}] =
             Fanout.pending_reports("alice", first_turn.thread_id, %{channel: "test"})

    assert :ok =
             Runtime.acknowledge_report_delivery(receipt, %{
               user_id: "alice",
               channel: "test",
               thread_id: first_turn.thread_id
             })

    assert Fanout.pending_reports("alice", first_turn.thread_id, %{channel: "test"}) == []
  end

  test "pending reports render truthful terminal reasons for non-success children" do
    assert {:ok, first_turn} =
             Runtime.submit_user_input(%{text: "hello", channel: :test, user_id: "alice"})

    assert {:ok, %{parent: parent, children: [completed, cancelled, failed]}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "Mixed work",
                 objective: "Mixed work",
                 source_channel: "test",
                 source_surface: "channel",
                 source_thread_id: first_turn.thread_id
               },
               ["completed task", "cancelled task", "failed task"]
             )

    assert {:ok, %{child: %{status: "completed"}}} =
             TerminalTransitions.terminalize_child(
               completed,
               %{
                 status: "completed",
                 last_observation_summary: "completed result",
                 completed_at: DateTime.utc_now()
               },
               "run_completed",
               %{}
             )

    assert {:ok, %{child: %{status: "cancelled"}}} =
             TerminalTransitions.terminalize_child(
               cancelled,
               %{
                 status: "cancelled",
                 last_observation_summary: "stale progress",
                 review_reason: "cancelled by operator",
                 completed_at: DateTime.utc_now()
               },
               "run_cancelled",
               %{}
             )

    assert {:ok, %{child: %{status: "failed"}}} =
             TerminalTransitions.terminalize_child(
               failed,
               %{
                 status: "failed",
                 review_reason: "provider unavailable",
                 completed_at: DateTime.utc_now()
               },
               "run_failed",
               %{}
             )

    select_queued_report!(parent.id)
    assert {:ok, _join} = Fanout.finalize_join(parent)

    assert {:ok, next_turn} =
             Runtime.submit_user_input(%{
               text: "report",
               channel: :test,
               user_id: "alice",
               thread_id: first_turn.thread_id
             })

    expected_report = Fanout.format_report(Fanout.report(parent))
    assert next_turn.message == "single: report\n\n#{expected_report}"
    assert next_turn.model_payload == "single: report\n\n#{expected_report}"
    assert next_turn.surface_payload == "single: report\n\n#{expected_report}"
    refute next_turn.message =~ "stale progress"
  end

  test "next Web turn acknowledges an already canonical report without repeating its text" do
    assert {:ok, first_turn} =
             Runtime.submit_user_input(%{text: "hello", channel: :live_view, user_id: "alice"})

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "Canonical before next turn",
                 objective: "Render exactly once",
                 source_channel: "live_view",
                 source_surface: "channel",
                 source_thread_id: first_turn.thread_id
               },
               ["one", "two"]
             )

    for child <- children do
      assert {:ok, _transition} =
               TerminalTransitions.terminalize_child(
                 child,
                 %{
                   status: "completed",
                   last_observation_summary: "done #{child.queue_position}",
                   completed_at: DateTime.utc_now()
                 },
                 "run_completed",
                 %{}
               )
    end

    select_queued_report!(parent.id)

    assert {:ok, canonical} =
             Runner.run(
               "persist_attached_fanout_report",
               %{thread_id: first_turn.thread_id, parent_id: parent.id},
               %{user_id: "alice"}
             )

    assert canonical.acknowledgement_required?

    assert {:ok, next_turn} =
             Runtime.submit_user_input(%{
               text: "what next?",
               channel: :live_view,
               user_id: "alice",
               thread_id: first_turn.thread_id
             })

    assert [%{parent_objective_id: parent_id}] = next_turn.pending_reports
    assert parent_id == parent.id
    assert next_turn.message == "single: what next?"
    refute next_turn.message =~ "Canonical before next turn"

    assert {:ok, thread} = Conversations.get_thread("alice", first_turn.thread_id)

    report_messages =
      thread
      |> Conversations.list_messages(limit: 20)
      |> Enum.filter(&(&1.metadata["parent_objective_id"] == parent.id))

    assert [_one_report] = report_messages

    assert :ok =
             Runtime.acknowledge_deliveries(next_turn, %{
               user_id: "alice",
               channel: "live_view",
               thread_id: first_turn.thread_id
             })

    assert Fanout.parent_projection(parent).parent.report_delivery_state == "delivered"
  end

  test "next Web turn canonicalizes a missed joined report before rendering it" do
    assert {:ok, first_turn} =
             Runtime.submit_user_input(%{text: "hello", channel: :live_view, user_id: "alice"})

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "Missed joined signal",
                 objective: "Converge through the next Web turn",
                 source_channel: "live_view",
                 source_surface: "channel",
                 source_thread_id: first_turn.thread_id
               },
               ["one", "two"]
             )

    for child <- children do
      assert {:ok, _transition} =
               TerminalTransitions.terminalize_child(
                 child,
                 %{
                   status: "completed",
                   last_observation_summary: "done #{child.queue_position}",
                   completed_at: DateTime.utc_now()
                 },
                 "run_completed",
                 %{}
               )
    end

    select_queued_report!(parent.id)

    assert {:ok, next_turn} =
             Runtime.submit_user_input(%{
               text: "what next?",
               channel: :live_view,
               user_id: "alice",
               thread_id: first_turn.thread_id
             })

    assert [%{parent_objective_id: parent_id}] = next_turn.pending_reports
    assert parent_id == parent.id
    assert next_turn.message == "single: what next?"
    refute next_turn.message =~ "Missed joined signal"

    assert {:ok, thread} = Conversations.get_thread("alice", first_turn.thread_id)

    report_messages =
      thread
      |> Conversations.list_messages(limit: 20)
      |> Enum.filter(&(&1.metadata["parent_objective_id"] == parent.id))

    assert [_one_report] = report_messages
    assert Fanout.parent_projection(parent).parent.report_delivery_state == "pending"

    assert :ok =
             Runtime.acknowledge_deliveries(next_turn, %{
               user_id: "alice",
               channel: "live_view",
               thread_id: first_turn.thread_id
             })

    assert Fanout.parent_projection(parent).parent.report_delivery_state == "delivered"
  end

  test "same user and thread on another channel cannot read or consume a pending report" do
    assert {:ok, first_turn} =
             Runtime.submit_user_input(%{text: "hello", channel: :test, user_id: "alice"})

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "Channel-bound report",
                 objective: "Keep the result on its origin channel",
                 source_channel: "test",
                 source_surface: "channel",
                 source_thread_id: first_turn.thread_id
               },
               ["one", "two"]
             )

    for child <- children do
      assert {:ok, _transition} =
               TerminalTransitions.terminalize_child(
                 child,
                 %{
                   status: "completed",
                   last_observation_summary: "origin-only result",
                   completed_at: DateTime.utc_now()
                 },
                 "run_completed",
                 %{}
               )
    end

    select_queued_report!(parent.id)

    assert {:ok, wrong_channel} =
             Runtime.submit_user_input(%{
               text: "show completed fan-out report",
               channel: :other,
               user_id: "alice",
               thread_id: first_turn.thread_id
             })

    refute wrong_channel.message =~ "Channel-bound report"
    assert Fanout.parent_projection(parent).parent.report_delivery_state == "pending"

    assert {:ok, origin_channel} =
             Runtime.submit_user_input(%{
               text: "show completed fan-out report",
               channel: :test,
               user_id: "alice",
               thread_id: first_turn.thread_id
             })

    assert origin_channel.message =~ "Channel-bound report"
    assert [%{parent_objective_id: parent_id}] = origin_channel.pending_reports
    assert parent_id == parent.id
  end

  test "next-turn report retrieval accepts a refreshed provider ref only for the same account" do
    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "Stable thread report",
                 objective: "Survive mutable provider metadata",
                 source_channel: "telegram",
                 source_thread_id: "canonical-thread",
                 origin_thread_ref_id: "41",
                 origin_thread_ref_digest: "stable-origin-digest",
                 origin_receiver_account_ref: "telegram:bot:primary"
               },
               ["one", "two"]
             )

    Enum.each(children, fn child ->
      assert {:ok, _transition} =
               TerminalTransitions.terminalize_child(
                 child,
                 %{status: "completed", completed_at: DateTime.utc_now()},
                 "run_completed",
                 %{}
               )
    end)

    select_queued_report!(parent.id)

    refreshed_ref = %{
      id: "99",
      channel: "telegram",
      receiver_account_ref: "telegram:bot:primary",
      provider_thread_ref: %{"message_id" => "new-message"}
    }

    assert [%{parent_objective_id: parent_id}] =
             Fanout.pending_reports("alice", "canonical-thread", %{
               channel: "telegram",
               channel_thread_ref: refreshed_ref
             })

    assert parent_id == parent.id

    assert [] =
             Fanout.pending_reports("alice", "canonical-thread", %{
               channel: "telegram",
               channel_thread_ref: %{
                 refreshed_ref
                 | receiver_account_ref: "telegram:bot:secondary"
               }
             })
  end

  test "an explicit fan-out report request returns active status or the joined report without intent routing" do
    assert {:ok, first_turn} =
             Runtime.submit_user_input(%{text: "hello", channel: :test, user_id: "alice"})

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "Controlled report",
                 objective: "Controlled report",
                 source_channel: "test",
                 source_surface: "channel",
                 source_thread_id: first_turn.thread_id
               },
               ["one", "two"]
             )

    test_pid = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, _request ->
        send(test_pid, :report_phrase_reached_agent)
        {:ok, %{message: ":missing_plan_source", status: :completed}}
      end
    )

    assert {:ok, active} =
             Runtime.submit_user_input(%{
               text: "show the completed fan-out report",
               channel: :test,
               user_id: "alice",
               thread_id: first_turn.thread_id
             })

    refute_received :report_phrase_reached_agent
    assert active.message =~ "still running"
    assert active.message =~ "1. one: open"
    refute active.message =~ "missing_plan_source"

    for child <- children do
      assert {:ok, %{child: %{status: "completed"}}} =
               TerminalTransitions.terminalize_child(
                 child,
                 %{
                   status: "completed",
                   last_observation_summary: "result #{child.queue_position + 1}",
                   completed_at: DateTime.utc_now()
                 },
                 "run_completed",
                 %{}
               )
    end

    select_queued_report!(parent.id)
    assert {:ok, _join} = Fanout.finalize_join(parent)

    assert {:ok, joined} =
             Runtime.submit_user_input(%{
               text: "show the completed fan-out report",
               channel: :test,
               user_id: "alice",
               thread_id: first_turn.thread_id
             })

    refute_received :report_phrase_reached_agent
    refute joined.message =~ "missing_plan_source"
    selected_body = Fanout.format_report(Fanout.report(parent))
    assert joined.message == "Completed fan-out report:\n\n#{selected_body}"
  end

  test "exact origin binding denies missing or changed account context" do
    assert {:ok, %{parent: parent, fanout_start_receipt: receipt}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "Bound work",
                 objective: "Bound work",
                 source_channel: "telegram",
                 source_surface: "channel",
                 source_thread_id: "thread-bound",
                 origin_thread_ref_digest: "digest-1",
                 origin_receiver_account_ref: "account-1"
               },
               ["one", "two"]
             )

    assert {:error, :receipt_identity_mismatch} =
             Fanout.acknowledge_start(receipt, %{
               user_id: "alice",
               thread_id: "thread-bound",
               channel: "telegram"
             })

    assert {:error, :receipt_identity_mismatch} =
             Fanout.acknowledge_start(receipt, %{
               user_id: "alice",
               thread_id: "thread-bound",
               channel: "telegram",
               origin_thread_ref_digest: "digest-1",
               origin_receiver_account_ref: "account-2"
             })

    assert :ok =
             Fanout.acknowledge_start(receipt, %{
               user_id: "alice",
               thread_id: "thread-bound",
               channel: "telegram",
               origin_thread_ref_digest: "digest-1",
               origin_receiver_account_ref: "account-1"
             })

    assert {:ok, acknowledged} = Objectives.get_objective(parent.id)
    assert acknowledged.kickoff_delivery_state == "acknowledged"
  end

  test "await continuation enforces ownership and returns bounded kickoff on timeout" do
    assert {:ok, %{parent: parent}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "Await work",
                 objective: "Await work",
                 source_channel: "openai_api",
                 source_surface: "api",
                 source_thread_id: "thread-await"
               },
               ["one", "two"]
             )

    assert {:error, :fanout_identity_mismatch} = Runtime.await_fanout(parent.id, "mallory", 0)

    assert {:timeout, kickoff} = Runtime.await_fanout(parent.id, "alice", 0)
    assert kickoff.parent_id == parent.id
    assert length(kickoff.children) == 2
  end

  test "await continuation returns a durably joined report when its publication is missed" do
    bus = :"runtime-fanout-wait-bus-#{System.unique_integer([:positive])}"
    bus_child = {:runtime_fanout_wait_bus, bus}
    _bus_pid = start_supervised!({Bus, name: bus}, id: bus_child)

    runtime_config = Application.get_env(:allbert_assist, Runtime, [])
    Application.put_env(:allbert_assist, Runtime, Keyword.put(runtime_config, :fanout_bus, bus))

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "Missed publication",
                 objective: "Recover the durable report",
                 source_channel: "openai_api",
                 source_surface: "api",
                 source_thread_id: "thread-missed-publication"
               },
               ["one", "two"]
             )

    waiter =
      Task.async(fn ->
        receive do
          :await -> Runtime.await_fanout(parent.id, "alice", 2_000)
        end
      end)

    Sandbox.allow(Repo, self(), waiter.pid)
    send(waiter.pid, :await)
    await_bus_subscription!(bus)

    Enum.each(children, fn child ->
      assert {:ok, _transition} =
               TerminalTransitions.terminalize_child(
                 child,
                 %{
                   status: "completed",
                   last_observation_summary: "done #{child.queue_position}",
                   completed_at: DateTime.utc_now()
                 },
                 "run_completed",
                 %{}
               )
    end)

    # Selection publishes to the production SignalBus. The waiter is
    # deliberately subscribed to the isolated bus and therefore receives no
    # joined wake-up; the timeout-boundary projection recheck must recover it.
    select_queued_report!(parent.id)

    assert {:ok, report} = Task.await(waiter, 3_000)
    assert report.parent_objective_id == parent.id
    assert is_binary(report.body)
  end

  test "confirm-before-start persists approval and resumes only through the registered action" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("objectives.fanout.confirm_before_start", true, %{audit?: false})

    assert {:ok, response} =
             Runtime.submit_user_input(%{
               text: "Do these two tasks in parallel: first task; second task",
               delivery_ack_capability: Runtime.fanout_delivery_ack_capability(),
               channel: :test,
               user_id: "alice"
             })

    assert response.status == :needs_confirmation
    confirmation_id = response.approval_handoff.confirmation_id
    assert is_binary(confirmation_id)
    assert Enum.all?(Fanout.children(response.fanout.parent_id), &(&1.run_attempt_count == 0))

    assert :ok =
             Runtime.acknowledge_deliveries(response, %{
               channel: "test",
               user_id: "alice",
               thread_id: response.thread_id
             })

    assert Enum.all?(Fanout.children(response.fanout.parent_id), &(&1.run_attempt_count == 0))

    assert {:ok, %{status: :completed}} =
             Runner.run("approve_confirmation", %{id: confirmation_id}, %{
               user_id: "alice",
               actor: "alice",
               channel: "test"
             })

    assert Enum.all?(
             await_fanout_terminal(response.fanout.parent_id),
             &(&1.status == "completed")
           )
  end

  test "missing or malformed delivery acknowledgement capability fails closed to one turn" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    for capability <- [nil, false, true, "fanout_delivery_ack_v2", :fanout_delivery_ack_v1] do
      request = %{
        text: "Do these two tasks in parallel: first task; second task",
        channel: :test,
        user_id: "unadapted-#{inspect(capability)}"
      }

      request =
        if is_nil(capability),
          do: request,
          else: Map.put(request, :delivery_ack_capability, capability)

      assert {:ok, response} = Runtime.submit_user_input(request)
      assert response.message =~ "single:"
      assert Map.get(response, :fanout) == nil
    end
  end

  defp manager_diagnostic do
    %{
      attempts: 1,
      model_profile: "direct_answer_local",
      model_profile_sha256: String.duplicate("a", 64),
      budget_limits: %{
        version: 1,
        max_model_calls: 40,
        max_output_tokens: 24_000,
        max_elapsed_ms: 300_000,
        max_worker_attempts_per_child: 2
      },
      plan_deadline_unix_ms: System.system_time(:millisecond) + 300_000
    }
  end

  defp select_queued_report!(parent_id) do
    assert {:ok, %{parent: %{id: ^parent_id}, frozen: frozen} = claim} =
             Fanout.claim_next_composition()

    assert {:ok, _selected} =
             Fanout.select_composition(
               claim,
               "deterministic_fallback",
               frozen.fallback_body,
               %{fallback_reason: "model_disabled"}
             )
  end

  defp await_bus_subscription!(bus, attempts \\ 100)

  defp await_bus_subscription!(_bus, 0), do: flunk("fan-out waiter did not subscribe")

  defp await_bus_subscription!(bus, attempts) do
    {:ok, bus_pid} = Bus.whereis(bus)

    if map_size(:sys.get_state(bus_pid).subscriptions) > 0 do
      :ok
    else
      Process.sleep(10)
      await_bus_subscription!(bus, attempts - 1)
    end
  end

  defp await_fanout_terminal(parent_id) do
    case Registry.lookup(AllbertAssist.Objectives.Runs.Registry, {:fanout, parent_id}) do
      [{coordinator, _value}] ->
        monitor_ref = Process.monitor(coordinator)
        assert_receive {:DOWN, ^monitor_ref, :process, ^coordinator, _reason}, 5_000

      [] ->
        :ok
    end

    children = Fanout.children(parent_id)

    assert Enum.all?(children, &(&1.status in ~w[completed cancelled failed abandoned])),
           "fan-out coordinator retired without terminalizing every child: #{inspect(children)}"

    children
  end
end
