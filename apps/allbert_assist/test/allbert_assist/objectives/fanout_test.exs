defmodule AllbertAssist.Objectives.FanoutTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  import Ecto.Query
  import ExUnit.CaptureLog

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.Report
  alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy
  alias AllbertAssist.Objectives.Fanout.ReportComposer
  alias AllbertAssist.Objectives.Fanout.TerminalTransitions
  alias AllbertAssist.Objectives.Lifecycle
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Objectives.Runs.CancelToken
  alias AllbertAssist.Repo
  alias Ecto.Adapters.SQL
  alias Jido.Signal.Bus

  defmodule CompletingAdapter do
    def operation(:execute, state, _opts),
      do: {:ok, Map.put(state, :response, %{message: "completed #{state.objective.title}"})}

    def operation(_operation, state, _opts), do: {:ok, state}
  end

  defmodule FailingAdapter do
    def operation(:execute, state, _opts), do: {:error, :fixture_failure, state}
    def operation(_operation, state, _opts), do: {:ok, state}
  end

  defmodule WakeScheduler do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call({:wake_parent, parent_id}, _from, owner) do
      send(owner, {:scheduler_wake, parent_id})
      {:reply, :ok, owner}
    end
  end

  test "frames parent and ordered children atomically without starting them" do
    assert {:ok, %{parent: parent, children: [first, second], fanout_start_receipt: receipt}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 source_thread_id: "thread-1",
                 source_channel: "telegram",
                 source_surface: "channel",
                 session_id: "session-1",
                 title: "Parallel work",
                 objective: "Do both tasks"
               },
               ["Research the topic", "Draft the summary"]
             )

    assert parent.fanout_role == "parent"
    assert parent.kickoff_delivery_state == "pending"
    assert parent.report_delivery_state == "not_ready"
    assert is_binary(receipt)
    refute parent.fanout_start_receipt_digest == receipt

    assert Enum.map([first, second], & &1.queue_position) == [0, 1]
    assert Enum.all?([first, second], &(&1.parent_objective_id == parent.id))
    assert Enum.all?([first, second], &(&1.status == "open"))
    assert Enum.map(Fanout.children(parent), & &1.id) == [first.id, second.id]

    identity = %{user_id: "alice", channel: "telegram", thread_id: "thread-1"}
    assert :ok = Fanout.acknowledge_start(receipt, identity)
    assert :ok = Fanout.acknowledge_start(receipt, identity)

    assert {:error, :receipt_identity_mismatch} =
             Fanout.acknowledge_start(receipt, Map.put(identity, :user_id, "mallory"))

    assert Enum.map(Objectives.list_events(parent.id), & &1.kind) == [
             "fanout_acknowledged",
             "fanout_proposed"
           ]
  end

  test "central recovery wake drains queued work and reconciles composing and legacy work" do
    scheduler = start_supervised!({WakeScheduler, self()})
    composer_name = :"fanout-wake-composer-#{System.unique_integer([:positive])}"

    composer =
      start_supervised!(
        {ReportComposer,
         name: composer_name, model_enabled?: false, reconcile_interval_ms: 60_000}
      )

    assert %{phase: :ready} = :sys.get_state(composer)

    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.objectives.fanout.joined")

    assert {:ok, %{parent: execution_parent}} =
             Fanout.frame(%{user_id: "alice", title: "execution", objective: "execution"}, [
               "first",
               "second"
             ])

    assert :ok =
             Fanout.wake_recovery(execution_parent,
               scheduler: scheduler,
               composer: composer_name
             )

    assert_receive {:scheduler_wake, parent_id}
    assert parent_id == execution_parent.id

    queued = queued_parent!("queued wake")
    assert :ok = Fanout.wake_recovery(queued, composer: composer_name, scheduler: scheduler)

    assert_receive {:signal,
                    %{type: "allbert.objectives.fanout.joined", subject: queued_parent_id}},
                   1_000

    assert queued_parent_id == queued.id
    assert {:ok, %{report_composition_state: "fallback"}} = Objectives.get_objective(queued.id)

    # v1.3 M9.b.12.d — this row is about the recovery wake draining queued work,
    # and the drained parent still lands on a deterministic fallback. The
    # *reason* changed: M9.b.6 put the budget-snapshot compatibility check ahead
    # of synthesis eligibility in ReportComposer.selected_body/2, so a
    # legacy-shaped parent — framed without a plan budget, exactly like a row
    # predating budgets — now reports the snapshot it lacks rather than the
    # unreviewed children it also has. Both paths reach the same fallback body,
    # so this is a precedence change in a diagnostic label, not a behaviour
    # change. `legacy_unreviewed_children` keeps its own direct coverage in
    # fanout_report_v2_test, fanout_report_composer_test, and
    # report_synthesis_agent_test.
    assert selection_payload(queued.id)["fallback_reason"] == "invalid_budget_snapshot"

    composing_queued = queued_parent!("composing wake")
    assert {:ok, %{parent: composing}} = Fanout.claim_next_composition()
    assert composing.id == composing_queued.id

    assert :ok = Fanout.wake_recovery(composing, composer: composer_name, scheduler: scheduler)

    assert_receive {:signal,
                    %{type: "allbert.objectives.fanout.joined", subject: composing_parent_id}},
                   1_000

    assert composing_parent_id == composing.id

    assert {:ok, %{report_composition_state: "fallback"}} =
             Objectives.get_objective(composing.id)

    assert selection_payload(composing.id)["fallback_reason"] == "recovery_after_restart"

    legacy_queued = queued_parent!("legacy wake")

    receipt_digest =
      :crypto.hash(:sha256, Fanout.receipt_for(:report, legacy_queued.id))
      |> Base.encode16(case: :lower)

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^legacy_queued.id)
             |> Repo.update_all(
               set: [
                 report_composition_state: "not_ready",
                 report_input_digest: nil,
                 report_delivery_state: "pending",
                 report_delivery_receipt_digest: receipt_digest
               ]
             )

    assert {:ok, legacy_pending} = Objectives.get_objective(legacy_queued.id)

    assert :ok =
             Fanout.wake_recovery(legacy_pending,
               composer: composer_name,
               scheduler: scheduler
             )

    assert_receive {:signal,
                    %{type: "allbert.objectives.fanout.joined", subject: legacy_parent_id}},
                   1_000

    assert legacy_parent_id == legacy_pending.id

    assert {:ok, %{report_composition_state: "fallback"}} =
             Objectives.get_objective(legacy_pending.id)

    assert selection_payload(legacy_pending.id)["fallback_reason"] == "historical_backfill"
    refute_receive {:scheduler_wake, _parent_id}
  end

  test "active parent lookup is scoped directly and cannot be starved by the list limit" do
    assert {:ok, %{parent: active_parent}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 source_thread_id: "target-thread",
                 title: "Older active fan-out",
                 objective: "Keep this fan-out visible to admission"
               },
               ["first", "second"]
             )

    older = DateTime.add(DateTime.utc_now(), -60, :second)

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^active_parent.id)
             |> Repo.update_all(set: [inserted_at: older, updated_at: older])

    for index <- 1..51 do
      assert {:ok, _unrelated} =
               Objectives.create_objective(%{
                 user_id: "alice",
                 source_thread_id: "other-thread-#{index}",
                 title: "Newer unrelated objective #{index}",
                 objective: "Unrelated work #{index}"
               })
    end

    refute Enum.any?(Objectives.list_objectives("alice"), &(&1.id == active_parent.id))

    assert {:ok, found} = Fanout.active_parent("alice", "target-thread")
    assert found.id == active_parent.id
    assert {:error, :not_found} = Fanout.active_parent("alice", "absent-thread")
    assert {:error, :not_found} = Fanout.active_parent("mallory", "target-thread")
  end

  test "recovering parent remains an admission boundary" do
    assert {:ok, %{parent: parent, children: children, fanout_start_receipt: receipt}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 source_thread_id: "recovering-thread",
                 title: "Recovering fan-out",
                 objective: "Finish durable reduction"
               },
               ["first", "second"]
             )

    assert :ok =
             Fanout.acknowledge_start(receipt, %{
               user_id: "alice",
               thread_id: "recovering-thread"
             })

    assert {2, _rows} =
             Objective
             |> where([objective], objective.id in ^Enum.map(children, & &1.id))
             |> Repo.update_all(
               set: [
                 status: "completed",
                 last_observation_summary: "durable result",
                 completed_at: DateTime.utc_now()
               ]
             )

    record_legacy_completion_events!(children, "durable result")

    assert Fanout.parent_projection(parent).phase == :recovering
    assert {:ok, found} = Fanout.active_parent("alice", "recovering-thread")
    assert found.id == parent.id

    assert {:error, {:fanout_already_active, refused_parent}} =
             Fanout.frame_if_inactive(
               %{
                 user_id: "alice",
                 source_thread_id: "recovering-thread",
                 title: "Nested fan-out",
                 objective: "Do not admit this fan-out"
               },
               ["third", "fourth"]
             )

    assert refused_parent.id == parent.id

    assert 1 ==
             Repo.aggregate(
               from(objective in Objective,
                 where:
                   objective.user_id == "alice" and
                     objective.source_thread_id == "recovering-thread" and
                     objective.fanout_role == "parent"
               ),
               :count,
               :id
             )

    assert {:ok, {:joined_now, joined}} = Fanout.reconcile_parent(parent)
    assert joined.report_composition_state == "queued"
    assert joined.report_delivery_state == "not_ready"
    assert {:ok, still_active} = Fanout.active_parent("alice", "recovering-thread")
    assert still_active.id == parent.id

    selected = select_fallback!(parent)
    assert selected.report_delivery_state == "pending"
    assert {:error, :not_found} = Fanout.active_parent("alice", "recovering-thread")

    assert {:ok, %{parent: successor}} =
             Fanout.frame_if_inactive(
               %{
                 user_id: "alice",
                 source_thread_id: "recovering-thread",
                 title: "Successor fan-out",
                 objective: "Admit work after the prior join"
               },
               ["third", "fourth"]
             )

    refute successor.id == parent.id
  end

  test "concurrent same-thread admissions frame exactly one durable parent" do
    caller = self()

    admissions =
      for index <- 1..2 do
        Task.async(fn ->
          send(caller, {:admission_ready, self()})
          receive do: (:admit -> :ok)

          Fanout.frame_if_inactive(
            %{
              user_id: "alice",
              source_thread_id: "concurrent-thread",
              title: "Concurrent fan-out #{index}",
              objective: "Only one request may frame"
            },
            ["first #{index}", "second #{index}"]
          )
        end)
      end

    pids =
      for _index <- 1..2 do
        assert_receive {:admission_ready, pid}
        pid
      end

    Enum.each(pids, &send(&1, :admit))
    results = Enum.map(admissions, &Task.await(&1, 2_000))

    assert 1 == Enum.count(results, &match?({:ok, %{parent: %Objective{}}}, &1))

    assert 1 ==
             Enum.count(results, &match?({:error, {:fanout_already_active, %Objective{}}}, &1))

    assert 1 ==
             Repo.aggregate(
               from(objective in Objective,
                 where:
                   objective.user_id == "alice" and
                     objective.source_thread_id == "concurrent-thread" and
                     objective.fanout_role == "parent"
               ),
               :count,
               :id
             )
  end

  test "scoped admission fails closed before writing when its durable scope is absent" do
    attrs = %{user_id: "alice", title: "Unscoped", objective: "Do not frame"}

    assert {:error, :fanout_admission_scope_required} =
             Fanout.frame_if_inactive(attrs, ["first", "second"])

    assert [] == Objectives.list_objectives("alice")
  end

  test "receipt identity normalizes atom and string forms for persisted surface channels" do
    for channel <- [:cli, :tui, :live_view, :telegram] do
      channel_name = Atom.to_string(channel)
      thread_id = "#{channel_name}-receipt-thread"

      assert {:ok, %{parent: parent, fanout_start_receipt: receipt}} =
               Fanout.frame(
                 %{
                   user_id: "#{channel_name}-operator",
                   source_thread_id: thread_id,
                   source_channel: channel,
                   title: "#{channel_name} receipt",
                   objective: "Acknowledge through the persisted channel identity"
                 },
                 ["first", "second"]
               )

      assert parent.source_channel == channel_name

      atom_context = %{
        user_id: parent.user_id,
        channel: channel,
        thread_id: thread_id
      }

      string_context = %{atom_context | channel: channel_name}

      assert :ok = Fanout.acknowledge_start(receipt, atom_context)
      assert :ok = Fanout.acknowledge_start(receipt, string_context)
      assert {:ok, %{id: parent_id}} = Fanout.parent_for_start_receipt(receipt, atom_context)
      assert parent_id == parent.id
    end
  end

  test "invalid child set rolls back the parent" do
    before_count = length(Objectives.list_objectives("alice"))

    assert {:error, :fanout_requires_at_least_two_children} =
             Fanout.frame(%{user_id: "alice", title: "Nope", objective: "Nope"}, ["one"])

    assert length(Objectives.list_objectives("alice")) == before_count
  end

  test "versioned and candidate-unversioned records enforce exact fan-out provenance" do
    assert {:ok, %{parent: parent, children: [parked, sibling]}} =
             Fanout.frame(
               %{user_id: "alice", title: "Legacy confirmation", objective: "Resume safely"},
               ["first", "second"]
             )

    confirmation_id = "conf_legacy_fanout"

    assert {:ok, parked_step} =
             Objectives.create_step(%{
               objective_id: parked.id,
               kind: "action",
               status: "selected",
               stage: "authorize_step",
               candidate_action: "list_objectives",
               action_params: %{}
             })

    modern_record = %{
      "id" => confirmation_id,
      "objective_binding_version" => 2,
      "objective_binding_kind" => "fanout_child",
      "objective_id" => parked.id,
      "step_id" => parked_step.id,
      "target_action" => %{"name" => "list_objectives"},
      "origin" => %{
        "user_id" => parked.user_id,
        "objective_id" => parked.id,
        "step_id" => parked_step.id,
        "parent_objective_id" => parked.parent_objective_id
      }
    }

    # Pushed candidate 107a5ce2 wrote trusted objective/step/parent/action
    # provenance but predated the binding version and kind. Only the newly
    # added owner field is absent from that real historical record shape.
    candidate_unversioned_record =
      modern_record
      |> Map.drop(["objective_binding_version", "objective_binding_kind"])
      |> update_in(["origin"], &Map.delete(&1, "user_id"))

    assert {:ok, %{child: binding_child, step: binding_step, phase: :binding}} =
             Objectives.fanout_confirmation_target(modern_record)

    assert binding_child.id == parked.id
    assert binding_step.id == parked_step.id

    assert {:ok, %{child: unversioned_child, step: unversioned_step, phase: :binding}} =
             Objectives.fanout_confirmation_target(candidate_unversioned_record)

    assert unversioned_child.id == parked.id
    assert unversioned_step.id == parked_step.id

    candidate_v1_record =
      modern_record
      |> Map.delete("objective_binding_kind")
      |> Map.put("objective_binding_version", 1)
      |> put_in(["origin"], %{})

    assert {:ok, %{child: v1_child, phase: :binding}} =
             Objectives.fanout_confirmation_target(candidate_v1_record)

    assert v1_child.id == parked.id

    objective_record =
      modern_record
      |> Map.put("objective_binding_kind", "objective")
      |> put_in(["origin"], %{})

    assert {:error, :stale_fanout_confirmation} =
             Objectives.fanout_confirmation_target(objective_record)

    assert {:ok, parked_step} =
             Objectives.transition_step(parked_step, "blocked", %{
               confirmation_id: confirmation_id
             })

    assert {:ok, _parked} =
             TerminalTransitions.transition_active_child(
               parked,
               %{status: "blocked", current_step_id: parked_step.id},
               "run_blocked",
               %{confirmation_id: confirmation_id}
             )

    assert {:ok, %{phase: :bound}} = Objectives.fanout_confirmation_target(modern_record)

    assert {:ok, %{phase: :bound}} =
             Objectives.fanout_confirmation_target(candidate_v1_record)

    assert {:ok, %{phase: :bound}} =
             Objectives.fanout_confirmation_target(candidate_unversioned_record)

    assert {:error, :stale_fanout_confirmation} =
             modern_record
             |> put_in(["target_action", "name"], "run_shell_command")
             |> Objectives.fanout_confirmation_target()

    assert {:error, :stale_fanout_confirmation} =
             modern_record
             |> put_in(["origin", "user_id"], "mallory")
             |> Objectives.fanout_confirmation_target()

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(set: [user_id: "mallory"])

    assert {:error, :stale_fanout_confirmation} =
             Objectives.fanout_confirmation_target(modern_record)

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(set: [user_id: parked.user_id])

    assert {:error, :stale_fanout_confirmation} =
             modern_record
             |> put_in(["origin", "parent_objective_id"], "fanout_wrong_parent")
             |> Objectives.fanout_confirmation_target()

    assert {:error, :stale_fanout_confirmation} =
             candidate_unversioned_record
             |> put_in(["target_action", "name"], "run_shell_command")
             |> Objectives.fanout_confirmation_target()

    assert {:error, :stale_fanout_confirmation} =
             candidate_unversioned_record
             |> put_in(["origin", "parent_objective_id"], "fanout_wrong_parent")
             |> Objectives.fanout_confirmation_target()

    assert {:ok, sibling_step} =
             Objectives.create_step(%{
               objective_id: sibling.id,
               kind: "action",
               status: "selected",
               stage: "authorize_step",
               candidate_action: "list_objectives",
               action_params: %{}
             })

    assert {:ok, _sibling_step} =
             Objectives.transition_step(sibling_step, "blocked", %{
               confirmation_id: confirmation_id
             })

    assert {:error, :ambiguous_confirmation_target} =
             Objectives.fanout_confirmation_target(modern_record)

    assert {:error, :ambiguous_confirmation_target} =
             Objectives.fanout_confirmation_target(candidate_unversioned_record)
  end

  test "provenance-free unversioned records use only a unique durable Step link" do
    assert {:ok, %{children: [parked, sibling]}} =
             Fanout.frame(
               %{user_id: "alice", title: "Older confirmation", objective: "Resume safely"},
               ["first", "second"]
             )

    confirmation_id = "conf_provenance_free_fanout"

    assert {:ok, parked_step} =
             Objectives.create_step(%{
               objective_id: parked.id,
               kind: "action",
               status: "selected",
               stage: "authorize_step",
               candidate_action: "list_objectives",
               action_params: %{}
             })

    assert {:ok, parked_step} =
             Objectives.transition_step(parked_step, "blocked", %{
               confirmation_id: confirmation_id
             })

    assert {:ok, _parked} =
             TerminalTransitions.transition_active_child(
               parked,
               %{status: "blocked", current_step_id: parked_step.id},
               "run_blocked",
               %{confirmation_id: confirmation_id}
             )

    # A pre-contract record has no binding version or top-level provenance;
    # its durable Step link remains upgrade-compatible, but only when unique.
    assert {:ok, %{child: target_child, step: target_step, phase: :bound}} =
             Objectives.fanout_confirmation_target(%{"id" => confirmation_id})

    assert target_child.id == parked.id
    assert target_step.id == parked_step.id

    assert {:ok, sibling_step} =
             Objectives.create_step(%{
               objective_id: sibling.id,
               kind: "action",
               status: "selected",
               stage: "authorize_step",
               candidate_action: "list_objectives",
               action_params: %{}
             })

    assert {:ok, _sibling_step} =
             Objectives.transition_step(sibling_step, "blocked", %{
               confirmation_id: confirmation_id
             })

    assert {:error, :ambiguous_confirmation_target} =
             Objectives.fanout_confirmation_target(%{"id" => confirmation_id})
  end

  test "the last public lifecycle completion atomically freezes and queues its parent report" do
    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{user_id: "alice", title: "Atomic join", objective: "Run every child"},
               ["first", "second", "third"]
             )

    for child <- children do
      assert {:ok, %{status: "completed"}} =
               Lifecycle.run(child.id, adapter: CompletingAdapter)
    end

    assert {:ok, joined} = Objectives.get_objective(parent.id)
    assert joined.status == "completed"
    assert joined.join_outcome == "success"
    assert joined.report_composition_state == "queued"
    assert joined.report_input_digest =~ ~r/\A[0-9a-f]{64}\z/
    assert joined.report_body == nil
    assert joined.report_source == nil
    assert joined.report_delivery_state == "not_ready"
    assert joined.report_delivery_receipt_digest == nil
    assert Fanout.parent_projection(parent).phase == :recovering
    refute Enum.any?(Fanout.runnable_parents(), &(&1.id == parent.id))

    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
    refute Enum.any?(Objectives.list_events(parent.id), &(&1.kind == "fanout_report_selected"))
  end

  test "composition claim and selection publish one stored authoritative report" do
    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{user_id: "alice", title: "Selected report", objective: "Run both children"},
               ["first", "second"]
             )

    Enum.each(children, fn child ->
      summary = "result #{child.queue_position}"

      assert {:ok, step} =
               Objectives.create_step(%{
                 objective_id: child.id,
                 kind: "action",
                 status: "completed",
                 stage: "execute_step",
                 candidate_action: "append_memory",
                 trace_id: "trace-selected-#{child.queue_position}",
                 result_summary: summary
               })

      complete_action_child!(child, step)
    end)

    assert {:ok, claim} = Fanout.claim_next_composition()
    assert claim.parent.id == parent.id
    assert claim.parent.report_composition_state == "composing"
    assert claim.frozen.input_digest == claim.parent.report_input_digest
    assert :none = Fanout.claim_next_composition()

    synthesis = "The two completed child results complement one another."

    assert {:ok, prepared} =
             Report.prepare_synthesis(
               claim.frozen.snapshot,
               accepted_synthesis_result(synthesis)
             )

    body = prepared.body
    assert body =~ "Model-authored advisory synthesis:"

    model_provenance = %{
      model_profile: "local",
      provider: "local_ollama",
      model: "llama3.2:3b",
      layout_version: prepared.layout.layout_version,
      sections: prepared.layout.sections,
      synthesis_contract_version: prepared.synthesis_contract_version,
      validation_outcome: prepared.validation_outcome,
      covered_queue_positions: prepared.covered_queue_positions,
      synthesis_sha256: prepared.synthesis_sha256
    }

    assert {:error, :invalid_fanout_report_provenance} =
             Fanout.select_composition(
               claim,
               "model",
               body,
               Map.put(model_provenance, :raw_error, "must never enter an event")
             )

    assert {:ok, selected} =
             Fanout.select_composition(claim, "model", body, model_provenance)

    assert selected.report_composition_state == "ready"
    assert selected.report_source == "model"
    assert selected.report_selection_digest =~ ~r/\A[0-9a-f]{64}\z/
    assert selected.report_body == body
    assert selected.report_delivery_state == "pending"
    assert is_binary(selected.report_delivery_receipt_digest)

    assert %{body: ^body, source: "model", input_digest: input_digest} = Fanout.report(selected)
    assert input_digest == claim.frozen.input_digest
    assert Fanout.format_report(Fanout.report(selected)) == body

    assert {:error, :stale_composition_claim} =
             Fanout.select_composition(claim, "model", body, model_provenance)

    assert [selection_event] =
             Enum.filter(
               Objectives.list_events(parent.id),
               &(&1.kind == "fanout_report_selected")
             )

    assert %{
             "source" => "model",
             "model_profile" => "local",
             "provider" => "local_ollama",
             "model" => "llama3.2:3b",
             "layout_version" => 2,
             "sections" => [
               %{
                 "relationship" => "complementary",
                 "ordered_queue_positions" => [0, 1]
               }
             ],
             "synthesis_contract_version" => 1,
             "validation_outcome" => "passed",
             "covered_queue_positions" => [0, 1],
             "synthesis_sha256" => synthesis_sha256
           } = Jason.decode!(selection_event.payload)

    assert synthesis_sha256 == prepared.synthesis_sha256

    refute selection_event.payload =~ "raw_error"

    assert Fanout.parent_projection(selected).phase == :joined

    original_payload = Jason.decode!(selection_event.payload)

    for tampered_payload <- [
          Map.put(original_payload, "model_profile", "another_valid_profile"),
          Map.put(original_payload, "provider", "another_valid_provider"),
          Map.put(original_payload, "model", "another_valid_model"),
          Map.put(original_payload, "layout_version", 1),
          put_in(
            original_payload,
            ["sections", Access.at(0), "relationship"],
            "supporting"
          )
        ] do
      assert {1, _rows} =
               AllbertAssist.Objectives.Event
               |> where([event], event.id == ^selection_event.id)
               |> Repo.update_all(set: [payload: Jason.encode!(tampered_payload)])

      assert %{phase: :inconsistent, authoritatively_joined?: false} =
               Fanout.parent_projection(parent)

      assert {1, _rows} =
               AllbertAssist.Objectives.Event
               |> where([event], event.id == ^selection_event.id)
               |> Repo.update_all(set: [payload: selection_event.payload])

      assert Fanout.parent_projection(parent).phase == :joined
    end

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(set: [report_selection_digest: String.duplicate("b", 64)])

    assert %{phase: :inconsistent, authoritatively_joined?: false} =
             Fanout.parent_projection(parent)

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(set: [report_selection_digest: selected.report_selection_digest])

    assert Fanout.parent_projection(parent).phase == :joined

    altered_body = selected.report_body <> "\n"

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(set: [report_body: altered_body])

    assert %{phase: :inconsistent, authoritatively_joined?: false} =
             Fanout.parent_projection(parent)

    assert %{body: nil} = Fanout.report(parent)
  end

  test "queued report input freezes completed action-step evidence" do
    assert {:ok, %{parent: parent, children: [first, second]}} =
             Fanout.frame(
               %{user_id: "alice", title: "Evidence freeze", objective: "Run both children"},
               ["first", "second"]
             )

    assert {:ok, action_step} =
             Objectives.create_step(%{
               objective_id: first.id,
               kind: "action",
               status: "completed",
               stage: "execute_step",
               candidate_action: "append_memory",
               trace_id: "trace-frozen",
               result_summary: "effect completed"
             })

    complete_action_child!(first, action_step)
    complete_legacy_child!(second)

    assert {:ok, frozen_before} = Fanout.report_input(parent.id)

    assert get_in(frozen_before, [:snapshot, :children, Access.at(0), :effect_receipt_ref]) == %{
             kind: "objective_step_trace",
             action: "append_memory",
             trace_id: "trace-frozen"
           }

    assert {:error, :fanout_report_input_frozen} =
             Objectives.update_step(action_step, %{trace_id: "trace-mutated"})

    assert {:error, :fanout_report_input_frozen} =
             Objectives.create_step(%{
               objective_id: first.id,
               kind: "action",
               status: "completed",
               stage: "execute_step",
               candidate_action: "late_action",
               trace_id: "trace-late"
             })

    assert {:ok, frozen_after} = Fanout.report_input(parent.id)
    assert frozen_after.input_digest == frozen_before.input_digest
  end

  test "database triggers freeze step insert update and delete, including legacy pending parents" do
    assert {:ok, %{parent: parent, children: [first, second]}} =
             Fanout.frame(
               %{user_id: "alice", title: "SQL freeze", objective: "Freeze evidence rows"},
               ["first", "second"]
             )

    assert {:ok, action_step} =
             Objectives.create_step(%{
               objective_id: first.id,
               kind: "action",
               status: "completed",
               stage: "execute_step",
               candidate_action: "append_memory",
               trace_id: "trace-before-freeze",
               result_summary: "effect completed"
             })

    complete_action_child!(first, action_step)
    complete_legacy_child!(second)

    assert {:ok, %{report_composition_state: "queued"}} =
             Objectives.get_objective(parent.id)

    assert_frozen_step_sql(
      """
      INSERT INTO objective_steps
        (id, objective_id, kind, status, stage, inserted_at, updated_at)
      VALUES (?, ?, 'action', 'completed', 'execute_step', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      [Objectives.new_id("step"), first.id]
    )

    assert_frozen_step_sql(
      "UPDATE objective_steps SET trace_id = ? WHERE id = ?",
      ["trace-after-freeze", action_step.id]
    )

    assert_frozen_step_sql("DELETE FROM objective_steps WHERE id = ?", [action_step.id])

    assert_frozen_child_sql(
      """
      INSERT INTO objectives
        (id, user_id, status, title, objective, fanout_role, parent_objective_id,
         queue_position, inserted_at, updated_at)
      VALUES (?, 'alice', 'open', 'late child', 'late child', 'child', ?, 2,
              CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
      """,
      [Objectives.new_id("obj"), parent.id]
    )

    assert_frozen_child_sql(
      "UPDATE objectives SET last_observation_summary = ? WHERE id = ?",
      ["mutated result", first.id]
    )

    assert_frozen_child_sql("DELETE FROM objectives WHERE id = ?", [second.id])

    assert_frozen_parent_sql(
      "UPDATE objectives SET title = ? WHERE id = ?",
      ["mutated parent input", parent.id]
    )

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(
               set: [
                 report_composition_state: "not_ready",
                 report_input_digest: nil,
                 report_delivery_state: "pending"
               ]
             )

    assert_frozen_step_sql(
      "UPDATE objective_steps SET trace_id = ? WHERE id = ?",
      ["trace-after-legacy-freeze", action_step.id]
    )

    assert_frozen_child_sql(
      "UPDATE objectives SET last_observation_summary = ? WHERE id = ?",
      ["mutated legacy result", first.id]
    )

    assert_frozen_parent_sql(
      "UPDATE objectives SET objective = ? WHERE id = ?",
      ["mutated legacy request", parent.id]
    )

    assert Repo.get!(AllbertAssist.Objectives.Step, action_step.id).trace_id ==
             "trace-before-freeze"
  end

  test "legacy pending recovery wakes delivery while delivered custody stays silent" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.objectives.fanout.joined")

    parents =
      for {title, delivery_state} <- [
            {"pending legacy", "pending"},
            {"delivered legacy", "delivered"}
          ] do
        assert {:ok, %{parent: parent, children: children}} =
                 Fanout.frame(
                   %{user_id: "alice", title: title, objective: "Recover selected report"},
                   ["first", "second"]
                 )

        Enum.each(children, &complete_legacy_child!/1)

        receipt_digest =
          :crypto.hash(:sha256, Fanout.receipt_for(:report, parent.id))
          |> Base.encode16(case: :lower)

        assert {1, _rows} =
                 Objective
                 |> where([objective], objective.id == ^parent.id)
                 |> Repo.update_all(
                   set: [
                     report_composition_state: "not_ready",
                     report_input_digest: nil,
                     report_body: nil,
                     report_source: nil,
                     report_delivery_state: delivery_state,
                     report_delivery_receipt_digest: receipt_digest
                   ]
                 )

        {parent.id, delivery_state, receipt_digest}
      end

    assert {:ok, 2} = Fanout.recover_composition()

    for {parent_id, delivery_state, receipt_digest} <- parents do
      assert {:ok, recovered} = Objectives.get_objective(parent_id)
      assert recovered.report_composition_state == "fallback"
      assert recovered.report_source == "deterministic_fallback"
      assert recovered.report_delivery_state == delivery_state
      assert recovered.report_delivery_receipt_digest == receipt_digest
      assert recovered.report_body =~ "Authoritative child results (ordered):"

      assert selected_event =
               Enum.find(
                 Objectives.list_events(parent_id),
                 &(&1.kind == "fanout_report_selected")
               )

      assert %{
               "fallback_reason" => "historical_backfill",
               "historical_backfill" => true
             } = Jason.decode!(selected_event.payload)
    end

    pending_id =
      parents |> Enum.find(fn {_id, state, _digest} -> state == "pending" end) |> elem(0)

    delivered_id =
      parents |> Enum.find(fn {_id, state, _digest} -> state == "delivered" end) |> elem(0)

    assert_receive {:signal, %{type: "allbert.objectives.fanout.joined", subject: ^pending_id}},
                   1_000

    refute_receive {:signal, %{type: "allbert.objectives.fanout.joined", subject: ^delivered_id}},
                   100
  end

  test "a corrupt oldest queued snapshot fails closed without blocking later valid work" do
    queued =
      for title <- ["oldest corrupt", "later valid"] do
        assert {:ok, %{parent: parent, children: children}} =
                 Fanout.frame(
                   %{user_id: "alice", title: title, objective: "Complete both children"},
                   ["first", "second"]
                 )

        Enum.each(children, &complete_legacy_child!/1)

        {parent, children}
      end

    [{corrupt_parent, _corrupt_children}, {valid_parent, _valid_children}] = queued

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^corrupt_parent.id)
             |> Repo.update_all(set: [report_input_digest: String.duplicate("0", 64)])

    assert %{phase: :inconsistent, composition_input_valid?: false} =
             Fanout.parent_projection(corrupt_parent)

    assert {:ok, claim} = Fanout.claim_next_composition()
    assert claim.parent.id == valid_parent.id
    assert :none = Fanout.claim_next_composition()

    assert {:ok, still_queued} = Objectives.get_objective(corrupt_parent.id)
    assert still_queued.report_composition_state == "queued"
    assert still_queued.report_delivery_state == "not_ready"
  end

  test "an over-limit queued parent is classified before authority queries and later work proceeds" do
    now = DateTime.utc_now()

    assert {:ok, corrupt_parent} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "over-limit corrupt parent",
               objective: "must be skipped before authority queries",
               fanout_role: "parent",
               join_policy: "all_terminal",
               join_outcome: "success",
               status: "completed",
               report_delivery_state: "not_ready",
               completed_at: DateTime.add(now, -10, :second)
             })

    corrupt_child_ids =
      for queue_position <- 0..16 do
        assert {:ok, child} =
                 Objectives.create_objective(%{
                   user_id: "alice",
                   title: "corrupt child #{queue_position}",
                   objective: "terminal child #{queue_position}",
                   fanout_role: "child",
                   parent_objective_id: corrupt_parent.id,
                   queue_position: queue_position,
                   status: "completed",
                   last_observation_summary: "corrupt result #{queue_position}",
                   completed_at: DateTime.add(now, -10, :second)
                 })

        child.id
      end

    assert {:ok, %{parent: valid_parent, children: valid_children}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "valid after over-limit parent",
                 objective: "complete both valid children"
               },
               ["first", "second"]
             )

    Enum.each(valid_children, fn child ->
      summary = "valid result #{child.queue_position}"

      assert {:ok, _transition} =
               TerminalTransitions.terminalize_child(
                 child,
                 %{
                   status: "completed",
                   last_observation_summary: summary,
                   completed_at: now
                 },
                 "run_completed",
                 %{summary: summary}
               )
    end)

    handler_id = {__MODULE__, self(), System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:allbert_assist, :repo, :query],
        fn _event, _measurements, metadata, {owner, corrupt_ids} ->
          query = to_string(Map.get(metadata, :query, ""))
          params = Map.get(metadata, :params, [])

          if (String.contains?(query, "objective_steps") or
                String.contains?(query, "objective_events")) and
               Enum.any?(params, &(&1 in corrupt_ids)) do
            send(owner, {:corrupt_authority_query, query})
          end
        end,
        {self(), corrupt_child_ids}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, :fanout_report_child_limit_exceeded} =
             Fanout.report_input_v2(corrupt_parent)

    refute_received {:corrupt_authority_query, _query}

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^corrupt_parent.id)
             |> Repo.update_all(
               set: [
                 report_composition_state: "queued",
                 report_input_digest: String.duplicate("0", 64)
               ]
             )

    assert {:ok, claim} = Fanout.claim_next_composition()
    assert claim.parent.id == valid_parent.id
    refute_received {:corrupt_authority_query, _query}

    assert {:ok, still_queued} = Objectives.get_objective(corrupt_parent.id)
    assert still_queued.report_composition_state == "queued"
    assert still_queued.report_input_digest == String.duplicate("0", 64)
  end

  test "composition claim scans beyond a full corrupt batch without starving valid work" do
    corrupt_parent_ids =
      for index <- 1..100 do
        assert {:ok, %{parent: parent, children: children}} =
                 Fanout.frame(
                   %{
                     user_id: "alice",
                     title: "corrupt #{index}",
                     objective: "Complete both children"
                   },
                   ["first", "second"]
                 )

        Enum.each(children, &complete_legacy_child!/1)

        parent.id
      end

    assert {:ok, %{parent: valid_parent, children: valid_children}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "valid after batch",
                 objective: "Complete both children"
               },
               ["first", "second"]
             )

    Enum.each(valid_children, &complete_legacy_child!/1)

    [invalid_event_parent_id | digest_mismatch_parent_ids] = corrupt_parent_ids

    assert {99, _rows} =
             Objective
             |> where([objective], objective.id in ^digest_mismatch_parent_ids)
             |> Repo.update_all(set: [report_input_digest: String.duplicate("0", 64)])

    invalid_event_child = invalid_event_parent_id |> Fanout.children() |> List.first()

    invalid_completion_event =
      AllbertAssist.Objectives.Event
      |> where(
        [event],
        event.objective_id == ^invalid_event_child.id and event.kind == "run_completed"
      )
      |> Repo.one!()

    invalid_payload =
      invalid_completion_event.payload
      |> Jason.decode!()
      |> Map.put("unexpected", true)
      |> Jason.encode!()

    assert {1, _rows} =
             AllbertAssist.Objectives.Event
             |> where([event], event.id == ^invalid_completion_event.id)
             |> Repo.update_all(set: [payload: invalid_payload])

    ordered_corrupt_ids =
      Objective
      |> where([objective], objective.id in ^corrupt_parent_ids)
      |> order_by([objective], asc: objective.completed_at, asc: objective.id)
      |> select([objective], objective.id)
      |> Repo.all()

    log =
      capture_log(fn ->
        assert {:ok, claim} = Fanout.claim_next_composition()
        assert claim.parent.id == valid_parent.id
      end)

    assert occurrence_count(
             log,
             "fan-out report composition skipped frozen-input integrity failures"
           ) == 2

    invalid_event_ids = Enum.filter(ordered_corrupt_ids, &(&1 == invalid_event_parent_id))
    mismatch_ids = Enum.reject(ordered_corrupt_ids, &(&1 == invalid_event_parent_id))

    assert log =~
             "reason=:invalid_fanout_report_completion_event count=1 " <>
               "first_parent_id=#{List.first(invalid_event_ids)} " <>
               "last_parent_id=#{List.last(invalid_event_ids)} " <>
               "parent_ids=#{Enum.join(invalid_event_ids, ",")}"

    assert log =~
             "reason=:fanout_report_input_mismatch count=99 " <>
               "first_parent_id=#{List.first(mismatch_ids)} " <>
               "last_parent_id=#{List.last(mismatch_ids)} " <>
               "parent_ids=#{Enum.join(mismatch_ids, ",")}"
  end

  test "boot recovery records a closed reason for a stranded composing fallback" do
    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: "recover composing",
                 objective: "Complete both children"
               },
               ["first", "second"]
             )

    Enum.each(children, &complete_legacy_child!/1)

    assert {:ok, %{parent: %{id: parent_id}}} = Fanout.claim_next_composition()
    assert parent_id == parent.id
    assert {:ok, 1} = Fanout.recover_composition()

    assert selected_event =
             Enum.find(
               Objectives.list_events(parent.id),
               &(&1.kind == "fanout_report_selected")
             )

    assert %{
             "source" => "deterministic_fallback",
             "fallback_reason" => "recovery_after_restart"
           } = Jason.decode!(selected_event.payload)
  end

  test "boot recovery skips corrupt composing work and leaves later queued work claimable" do
    queued =
      for title <- ["stranded composing", "later queued"] do
        assert {:ok, %{parent: parent, children: children}} =
                 Fanout.frame(
                   %{user_id: "alice", title: title, objective: "Complete both children"},
                   ["first", "second"]
                 )

        Enum.each(children, &complete_legacy_child!/1)

        {parent, children}
      end

    [{stranded, _stranded_children}, {later, _children}] = queued
    assert {:ok, %{parent: %{id: stranded_id}}} = Fanout.claim_next_composition()
    assert stranded_id == stranded.id

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^stranded.id)
             |> Repo.update_all(set: [report_input_digest: String.duplicate("0", 64)])

    assert {:ok, 0} = Fanout.recover_composition()
    assert %{phase: :inconsistent} = Fanout.parent_projection(stranded)

    assert {:ok, %{parent: %{id: later_id}}} = Fanout.claim_next_composition()
    assert later_id == later.id

    assert {:ok, unchanged} = Objectives.get_objective(stranded.id)
    assert unchanged.report_composition_state == "composing"
    assert unchanged.report_delivery_state == "not_ready"
  end

  test "boot recovery bounds each scan batch and aggregates every corrupt parent by reason" do
    composing_parent_ids =
      for index <- 1..101 do
        assert {:ok, %{parent: parent, children: children}} =
                 Fanout.frame(
                   %{
                     user_id: "alice",
                     title: "corrupt recovery #{index}",
                     objective: "Complete both children"
                   },
                   ["first", "second"]
                 )

        Enum.each(children, &complete_legacy_child!/1)
        assert {:ok, %{parent: claimed}} = Fanout.claim_next_composition()
        assert claimed.id == parent.id
        parent.id
      end

    ordered_parent_ids =
      Objective
      |> where([objective], objective.id in ^composing_parent_ids)
      |> order_by([objective], asc: objective.completed_at, asc: objective.id)
      |> select([objective], objective.id)
      |> Repo.all()

    [invalid_event_parent_id | digest_mismatch_parent_ids] = ordered_parent_ids

    assert {100, _rows} =
             Objective
             |> where([objective], objective.id in ^digest_mismatch_parent_ids)
             |> Repo.update_all(set: [report_input_digest: String.duplicate("0", 64)])

    invalid_event_child = invalid_event_parent_id |> Fanout.children() |> List.first()

    invalid_completion_event =
      AllbertAssist.Objectives.Event
      |> where(
        [event],
        event.objective_id == ^invalid_event_child.id and event.kind == "run_completed"
      )
      |> Repo.one!()

    invalid_payload =
      invalid_completion_event.payload
      |> Jason.decode!()
      |> Map.put("unexpected", true)
      |> Jason.encode!()

    assert {1, _rows} =
             AllbertAssist.Objectives.Event
             |> where([event], event.id == ^invalid_completion_event.id)
             |> Repo.update_all(set: [payload: invalid_payload])

    first_batch_ids = Enum.take(ordered_parent_ids, 100)
    first_batch_mismatch_ids = Enum.reject(first_batch_ids, &(&1 == invalid_event_parent_id))
    second_batch_mismatch_ids = Enum.drop(ordered_parent_ids, 100)

    log =
      capture_log(fn ->
        assert {:ok, 0} = Fanout.recover_composition()
      end)

    assert occurrence_count(
             log,
             "fan-out report composition skipped frozen-input integrity failures"
           ) == 3

    assert log =~
             "reason=:invalid_fanout_report_completion_event count=1 " <>
               "first_parent_id=#{invalid_event_parent_id} " <>
               "last_parent_id=#{invalid_event_parent_id} " <>
               "parent_ids=#{invalid_event_parent_id}"

    assert log =~
             "reason=:fanout_report_input_mismatch count=99 " <>
               "first_parent_id=#{List.first(first_batch_mismatch_ids)} " <>
               "last_parent_id=#{List.last(first_batch_mismatch_ids)} " <>
               "parent_ids=#{Enum.join(first_batch_mismatch_ids, ",")}"

    assert log =~
             "reason=:fanout_report_input_mismatch count=1 " <>
               "first_parent_id=#{List.first(second_batch_mismatch_ids)} " <>
               "last_parent_id=#{List.last(second_batch_mismatch_ids)} " <>
               "parent_ids=#{Enum.join(second_batch_mismatch_ids, ",")}"
  end

  test "concurrent final siblings reduce to one queue and one stable selected report receipt" do
    for iteration <- 1..12 do
      assert {:ok, %{parent: parent, children: children}} =
               Fanout.frame(
                 %{
                   user_id: "alice",
                   title: "Concurrent join #{iteration}",
                   objective: "Commit both final siblings"
                 },
                 ["first", "second"]
               )

      tasks =
        Enum.map(children, fn child ->
          Task.async(fn ->
            receive do: (:go -> :ok)

            summary = "result #{child.queue_position}"

            TerminalTransitions.terminalize_child(
              child,
              %{
                status: "completed",
                last_observation_summary: summary,
                completed_at: DateTime.utc_now()
              },
              "run_completed",
              %{summary: summary}
            )
          end)
        end)

      Enum.each(tasks, &send(&1.pid, :go))

      assert Enum.all?(tasks, fn task ->
               match?({:ok, %{child: %{status: "completed"}}}, Task.await(task, 2_000))
             end)

      assert %{phase: :recovering, parent: queued, children: terminal_children} =
               Fanout.parent_projection(parent)

      assert Enum.all?(terminal_children, &(&1.status == "completed"))
      assert queued.report_composition_state == "queued"
      assert queued.report_delivery_state == "not_ready"
      assert queued.report_delivery_receipt_digest == nil

      joined = select_fallback!(parent)
      assert Fanout.parent_projection(joined).phase == :joined

      assert joined.report_delivery_receipt_digest ==
               :crypto.hash(:sha256, Fanout.receipt_for(:report, parent.id))
               |> Base.encode16(case: :lower)

      assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
    end
  end

  test "a public lifecycle failure atomically joins the mixed parent" do
    assert {:ok, %{parent: parent, children: [completed, failed]}} =
             Fanout.frame(
               %{user_id: "alice", title: "Mixed atomic join", objective: "Run every child"},
               ["complete", "fail"]
             )

    assert {:ok, %{status: "completed"}} =
             Lifecycle.run(completed.id, adapter: CompletingAdapter)

    assert {:error, :fixture_failure} = Lifecycle.run(failed.id, adapter: FailingAdapter)

    assert {:ok, joined} = Objectives.get_objective(parent.id)
    assert joined.status == "completed"
    assert joined.join_outcome == "partial"
    assert joined.report_composition_state == "queued"
    assert joined.report_delivery_state == "not_ready"
    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "a public lifecycle cancellation atomically joins the mixed parent" do
    assert {:ok, %{parent: parent, children: [completed, cancelled]}} =
             Fanout.frame(
               %{user_id: "alice", title: "Cancelled atomic join", objective: "Run children"},
               ["complete", "cancel"]
             )

    assert {:ok, %{status: "completed"}} =
             Lifecycle.run(completed.id, adapter: CompletingAdapter)

    cancel_token = CancelToken.new()
    assert :ok = CancelToken.cancel(cancel_token)

    assert {:ok, %{status: "cancelled"}} =
             Lifecycle.run(cancelled.id,
               adapter: CompletingAdapter,
               cancel_token: cancel_token
             )

    assert {:ok, joined} = Objectives.get_objective(parent.id)
    assert joined.status == "completed"
    assert joined.join_outcome == "partial"
    assert joined.report_composition_state == "queued"
    assert joined.report_delivery_state == "not_ready"
    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "join reduction and report enumerate partial outcomes" do
    assert {:ok, %{parent: parent, children: [first, second]}} =
             Fanout.frame(
               %{user_id: "alice", title: "Parallel", objective: "Parallel"},
               ["First", "Second"]
             )

    assert {:ok, %{status: "completed"}} =
             Lifecycle.run(first.id, adapter: CompletingAdapter)

    assert {:error, :fixture_failure} = Lifecycle.run(second.id, adapter: FailingAdapter)

    assert %{terminal?: true, status: "completed", outcome: "partial"} =
             Fanout.join_status(parent)

    assert {:error, :fanout_report_composition_pending} = Fanout.finalize_join(parent)
    selected = select_fallback!(parent)

    assert {:ok, %{parent: joined, report_delivery_receipt: report_receipt}} =
             Fanout.finalize_join(selected)

    assert joined.join_outcome == "partial"
    assert joined.report_delivery_state == "pending"
    assert :ok = Fanout.acknowledge_report(report_receipt, %{user_id: "alice"})
    assert :ok = Fanout.acknowledge_report(report_receipt, %{user_id: "alice"})

    assert Enum.map(Objectives.list_events(parent.id), & &1.kind) == [
             "report_delivered",
             "fanout_report_selected",
             "fanout_joined",
             "fanout_proposed"
           ]

    assert %{children: children, join_outcome: "partial"} = Fanout.report(parent)
    assert Enum.map(children, & &1.status) == ["completed", "failed"]
  end

  test "an all-terminal open parent is repaired idempotently" do
    assert {:ok, %{parent: parent, children: children, fanout_start_receipt: receipt}} =
             Fanout.frame(
               %{user_id: "alice", title: "Historical orphan", objective: "Repair parent"},
               ["first", "second"]
             )

    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    for child <- children do
      assert {1, _rows} =
               Objective
               |> where([objective], objective.id == ^child.id)
               |> Repo.update_all(
                 set: [
                   status: "completed",
                   last_observation_summary: "historical result",
                   completed_at: DateTime.utc_now()
                 ]
               )
    end

    record_legacy_completion_events!(children, "historical result")

    assert {:ok, {:joined_now, joined}} = Fanout.reconcile_parent(parent.id)
    assert joined.status == "completed"
    assert joined.report_composition_state == "queued"
    assert joined.report_delivery_state == "not_ready"

    assert {:ok, {:already_joined, same_parent}} = Fanout.reconcile_parent(parent.id)
    assert same_parent.id == joined.id
    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1

    assert select_fallback!(parent).report_delivery_state == "pending"
  end

  test "stale abandonment never starts or completes an undelivered fan-out" do
    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{user_id: "alice", title: "Undelivered fan-out", objective: "Wait for delivery"},
               ["first", "second"]
             )

    stale = DateTime.add(DateTime.utc_now(), -2, :hour)

    assert {3, _rows} =
             Objective
             |> where([objective], objective.id in ^[parent.id | Enum.map(children, & &1.id)])
             |> Repo.update_all(set: [updated_at: stale])

    assert {:ok, 0} = Objectives.abandon_stale_objectives(now: DateTime.utc_now())

    assert %{phase: :awaiting_kickoff, parent: unchanged} = Fanout.parent_projection(parent)
    assert unchanged.report_delivery_state == "not_ready"
    assert Enum.all?(Fanout.children(parent), &(&1.status == "open"))
    refute Enum.any?(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined"))
  end

  test "stale abandonment terminalizes children and derives the parent once" do
    assert {:ok, %{parent: parent, children: children, fanout_start_receipt: receipt}} =
             Fanout.frame(
               %{user_id: "alice", title: "Stale fan-out", objective: "Recover stale work"},
               ["first", "second"]
             )

    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    stale = DateTime.add(DateTime.utc_now(), -2, :hour)
    ids = [parent.id | Enum.map(children, & &1.id)]

    assert {3, _rows} =
             Objective
             |> where([objective], objective.id in ^ids)
             |> Repo.update_all(set: [updated_at: stale])

    assert {:ok, 2} = Objectives.abandon_stale_objectives(now: DateTime.utc_now())

    assert Enum.all?(children, fn child ->
             match?({:ok, %{status: "abandoned"}}, Objectives.get_objective(child.id))
           end)

    assert {:ok,
            %{
              status: "failed",
              join_outcome: "failed",
              report_composition_state: "queued",
              report_delivery_state: "not_ready"
            }} = Objectives.get_objective(parent.id)

    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "child report detail is bounded and prioritizes truthful terminal reasons" do
    assert Fanout.report_child_detail(%{
             status: "completed",
             result_summary: String.duplicate("x", 600),
             review_reason: nil
           }) == String.duplicate("x", 500)

    assert Fanout.report_child_detail(%{
             status: "cancelled",
             result_summary: "stale progress",
             review_reason: "cancelled by operator"
           }) == "cancelled by operator"

    assert Fanout.report_child_detail(%{status: "failed"}) ==
             "No terminal reason recorded."
  end

  test "frozen report input is canonical, redacted, ordered, and renders every terminal child" do
    parent = %Objective{
      id: "fanout_report_parent",
      title: "Parallel investigation",
      objective: "Compare both results using token=Bearer raw-secret",
      fanout_role: "parent",
      status: "completed",
      join_outcome: "partial",
      proposer_hint:
        Jason.encode!(%{
          "fanout_plan" => %{
            "version" => 1,
            "source" => "adaptive_manager",
            "plan_sha256" => String.duplicate("b", 64),
            "original_request_sha256" => String.duplicate("c", 64),
            "budget" => %{"composer_calls" => 1},
            "deadline_unix_ms" => 1_800_000_000_000
          }
        })
    }

    children = [
      %Objective{
        id: "obj_second",
        queue_position: 1,
        title: "Second",
        objective: "Inspect second",
        fanout_role: "child",
        acceptance_criteria: Jason.encode!(%{"summary" => "Second evidence"}),
        status: "failed",
        review_reason: "provider failed"
      },
      %Objective{
        id: "obj_first",
        queue_position: 0,
        title: "First",
        objective: "Inspect first",
        fanout_role: "child",
        acceptance_criteria: Jason.encode!(%{"summary" => "First evidence"}),
        status: "completed",
        last_observation_summary: "first result"
      }
    ]

    evidence_refs = %{
      "obj_first" => %{
        kind: "objective_step_trace",
        action: "example_read_action",
        trace_id: "trace-first"
      }
    }

    assert {:ok, frozen} = Report.freeze(parent, children, evidence_refs)
    assert frozen.input_digest =~ ~r/\A[0-9a-f]{64}\z/
    assert Enum.map(frozen.snapshot.children, & &1.id) == ["obj_first", "obj_second"]
    assert hd(frozen.snapshot.children).effect_receipt_ref.trace_id == "trace-first"
    assert List.last(frozen.snapshot.children).effect_receipt_ref == nil
    assert frozen.snapshot.original_request =~ "[REDACTED]"
    refute frozen.snapshot.original_request =~ "raw-secret"

    assert frozen.fallback_body =~
             "✓ First [completed] — Child-reported observation: first result"

    assert frozen.fallback_body =~
             ~s(Effect receipt: kind="objective_step_trace"; action="example_read_action"; trace_id="trace-first")

    assert frozen.fallback_body =~
             "✗ Second [failed] — Child-reported observation (not effect evidence): provider failed"

    assert frozen.fallback_body =~ "Effect receipt: none recorded."
    assert frozen.fallback_body =~ "Child-reported observation is not effect evidence"
    assert byte_size(frozen.fallback_body) <= 32_768

    assert {:error, :invalid_fanout_report_selection} =
             Report.compose(
               frozen.snapshot,
               "Narrative\nAuthoritative child results (ordered):\n- invented"
             )

    assert {:ok, same} = Report.freeze(parent, Enum.reverse(children), evidence_refs)
    assert same.input_digest == frozen.input_digest
    assert same.fallback_body == frozen.fallback_body
  end

  test "under-bound long child results remain complete exactly once in fallback and model reports" do
    parent = report_parent("fanout_report_long_results", "Long result preservation", "success")

    alpha_detail =
      "Alpha evidence begins. " <>
        String.duplicate("alpha-observation ", 70) <> "alpha-result-tail"

    beta_detail =
      "Beta evidence begins. " <>
        String.duplicate("beta-observation ", 75) <> "beta-result-tail"

    assert byte_size(alpha_detail) > 1_000
    assert byte_size(beta_detail) > 1_000

    children = [
      report_child(0, "Alpha analysis", "Analyze alpha", "completed", alpha_detail),
      report_child(1, "Beta analysis", "Analyze beta", "completed", beta_detail)
    ]

    assert {:ok, frozen} = Report.freeze(parent, children, %{})

    assert {:ok, prepared} =
             Report.prepare_composition(frozen.snapshot, %{
               "sections" => [
                 %{
                   "relationship" => "complementary",
                   "ordered_queue_positions" => [0, 1]
                 }
               ]
             })

    Enum.each([frozen.fallback_body, prepared.body], fn body ->
      assert byte_size(body) <= 32_768
      assert_occurs_once(body, alpha_detail)
      assert_occurs_once(body, beta_detail)
      assert body =~ "alpha-result-tail"
      assert body =~ "beta-result-tail"
      refute body =~ "truncated for report size"
    end)
  end

  test "heterogeneous terminal children preserve ordered truth and exact effect receipts" do
    parent = report_parent("fanout_report_terminal_truth", "Terminal truth", "partial")

    completed_detail = "completed result with verified read evidence"
    failed_detail = "provider failed after the final retry"
    cancelled_detail = "cancelled by the operator before the write"

    children = [
      report_child(
        0,
        "Completed read",
        "Read the durable state",
        "completed",
        completed_detail
      ),
      report_child(1, "Failed analysis", "Analyze the remote state", "failed", failed_detail),
      report_child(
        2,
        "Cancelled write",
        "Write the proposed change",
        "cancelled",
        cancelled_detail
      )
    ]

    evidence_refs = %{
      "obj-report-0" => %{
        kind: "objective_step_trace",
        action: "read_durable_state",
        trace_id: "trace-terminal-completed"
      }
    }

    assert {:ok, frozen} = Report.freeze(parent, Enum.reverse(children), evidence_refs)

    assert {:ok, prepared} =
             Report.prepare_composition(frozen.snapshot, %{
               "sections" => [
                 %{"relationship" => "independent", "ordered_queue_positions" => [0]}
               ]
             })

    exact_receipt =
      ~s(Effect receipt: kind="objective_step_trace"; action="read_durable_state"; trace_id="trace-terminal-completed")

    no_receipt =
      "Effect receipt: none recorded. Child-reported observation is not effect evidence."

    Enum.each([frozen.fallback_body, prepared.body], fn body ->
      assert_occurs_once(body, completed_detail)
      assert_occurs_once(body, failed_detail)
      assert_occurs_once(body, cancelled_detail)
      assert_occurs_once(body, exact_receipt)
      assert occurrence_count(body, no_receipt) == 2

      authoritative =
        body
        |> String.split("Authoritative child results (ordered):", parts: 2)
        |> List.last()

      assert_ordered(authoritative, [
        "Completed read [completed]",
        "Failed analysis [failed]",
        "Cancelled write [cancelled]"
      ])

      assert body =~
               "Failed analysis [failed] — Child-reported observation (not effect evidence): #{failed_detail}"

      assert body =~
               "Cancelled write [cancelled] — Child-reported observation (not effect evidence): #{cancelled_detail}"
    end)
  end

  test "over-bound Unicode and unbroken results preserve all sixteen children with explicit markers" do
    {parent, children, evidence_refs, selection} = over_bound_report_fixture()

    assert {:ok, frozen} = Report.freeze(parent, children, evidence_refs)
    assert {:ok, prepared} = Report.prepare_composition(frozen.snapshot, selection)

    Enum.each([frozen.fallback_body, prepared.body], fn body ->
      assert String.valid?(body)
      assert byte_size(body) <= 32_768

      Enum.each(children, fn child ->
        marker =
          "… [truncated for report size; full result: Objective #{child.id}]"

        assert_occurs_once(body, marker)
        assert body =~ child.title
        assert body =~ overflow_detail_prefix(child.queue_position)
        assert body =~ ~s(trace_id="trace-overflow-#{child.queue_position}")
      end)

      last_child = List.last(children)

      assert String.ends_with?(
               body,
               ~s(trace_id="trace-overflow-#{last_child.queue_position}")
             )
    end)
  end

  test "over-bound report allocation is deterministic across replay and child input order" do
    {parent, children, evidence_refs, selection} = over_bound_report_fixture()

    assert {:ok, first} = Report.freeze(parent, children, evidence_refs)
    assert {:ok, replayed} = Report.freeze(parent, children, evidence_refs)
    assert {:ok, reversed} = Report.freeze(parent, Enum.reverse(children), evidence_refs)

    assert first.input_digest == replayed.input_digest
    assert first.input_digest == reversed.input_digest
    assert first.fallback_body == replayed.fallback_body
    assert first.fallback_body == reversed.fallback_body

    assert {:ok, first_model} = Report.prepare_composition(first.snapshot, selection)
    assert {:ok, replayed_model} = Report.prepare_composition(replayed.snapshot, selection)
    assert {:ok, reversed_model} = Report.prepare_composition(reversed.snapshot, selection)

    assert first_model.body == replayed_model.body
    assert first_model.body == reversed_model.body

    Enum.each(children, fn child ->
      marker = "… [truncated for report size; full result: Objective #{child.id}]"
      assert first.fallback_body =~ marker
      assert first_model.body =~ marker
    end)
  end

  test "maximum admitted metadata preserves the explicit result-pointer floor" do
    parent = %Objective{
      id: "fanout_report_maximum_metadata",
      title: "Maximum metadata " <> String.duplicate("\"\\", 90),
      objective: String.duplicate("parent-request ", 250),
      fanout_role: "parent",
      status: "completed",
      join_outcome: "success"
    }

    children =
      Enum.map(0..15, fn position ->
        %Objective{
          id: "obj-maximum-metadata-#{String.pad_leading(to_string(position), 2, "0")}",
          queue_position: position,
          title: "Maximum child #{position} " <> String.duplicate("\"\\", 85),
          objective: "Objective #{position} " <> String.duplicate("\"\\", 1_900),
          fanout_role: "child",
          status: "completed",
          last_observation_summary:
            String.duplicate("bounded-word-#{position} ", 100) <> "maximum-tail-#{position}"
        }
      end)

    trace_id = String.duplicate("t", 128)

    evidence_refs =
      Map.new(children, fn child ->
        {child.id,
         %{
           kind: String.duplicate("k", 40),
           action: String.duplicate("\"", 240),
           trace_id: trace_id
         }}
      end)

    selection = %{
      "sections" => [
        %{
          "relationship" => "complementary",
          "ordered_queue_positions" => Enum.to_list(0..15)
        }
      ]
    }

    assert {:ok, frozen} = Report.freeze(parent, children, evidence_refs)
    assert {:ok, prepared} = Report.prepare_composition(frozen.snapshot, selection)

    Enum.each([frozen.fallback_body, prepared.body], fn body ->
      assert byte_size(body) <= 32_768
      refute body =~ "Authoritative child result references (ordered):"

      Enum.each(children, fn child ->
        assert body =~
                 "… [truncated for report size; full result: Objective #{child.id}]"
      end)

      assert String.ends_with?(body, ~s(trace_id="#{trace_id}"))
    end)
  end

  test "one durable parent projection distinguishes running, recovery, joined, and corruption" do
    assert {:ok, %{parent: parent, children: children, fanout_start_receipt: receipt}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 source_channel: "tui",
                 source_thread_id: "projection-thread",
                 title: "Projection truth",
                 objective: "Project one durable fan-out"
               },
               ["first", "second"]
             )

    assert %{
             phase: :awaiting_kickoff,
             children_terminal?: false,
             authoritatively_joined?: false,
             recovery_required?: false
           } = Fanout.parent_projection(parent)

    assert :ok =
             Fanout.acknowledge_start(receipt, %{
               user_id: "alice",
               channel: "tui",
               thread_id: "projection-thread"
             })

    assert %{phase: :running, display_status: "running", recovery_required?: true} =
             Fanout.parent_projection(parent)

    # Simulate the exact pre-M12.15 crash orphan: child terminal rows committed,
    # but the parent reduction did not. Production writers cannot create this.
    assert {2, _rows} =
             Objective
             |> where([objective], objective.id in ^Enum.map(children, & &1.id))
             |> Repo.update_all(
               set: [
                 status: "completed",
                 last_observation_summary: "durable result",
                 completed_at: DateTime.utc_now()
               ]
             )

    record_legacy_completion_events!(children, "durable result")

    assert %{
             phase: :recovering,
             display_status: "finalizing",
             children_terminal?: true,
             authoritatively_joined?: false
           } = Fanout.parent_projection(parent)

    assert {:ok, {:joined_now, joined}} = Fanout.reconcile_parent(parent)

    assert %{phase: :recovering, display_status: "finalizing"} =
             Fanout.parent_projection(joined)

    selected = select_fallback!(parent)

    assert %{
             phase: :joined,
             display_status: "completed",
             authoritatively_joined?: true,
             persisted_join_outcome: "success",
             derived_join_outcome: "success"
           } = Fanout.parent_projection(selected)

    assert_frozen_parent_sql(
      "UPDATE objectives SET join_outcome = 'partial' WHERE id = ?",
      [parent.id]
    )

    assert %{phase: :joined, display_status: "completed"} = Fanout.parent_projection(parent)
  end

  test "an empty fan-out parent is inconsistent rather than terminal" do
    assert {:ok, parent} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Empty parent",
               objective: "No children",
               fanout_role: "parent"
             })

    assert %{
             phase: :inconsistent,
             children: [],
             children_terminal?: false,
             authoritatively_joined?: false
           } = Fanout.parent_projection(parent)
  end

  test "pending report reads exclude a corrupted non-joined parent" do
    assert {:ok, %{parent: parent}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 source_thread_id: "corrupt-report-thread",
                 title: "Corrupt outbox",
                 objective: "Never present a false report"
               },
               ["one", "two"]
             )

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(
               set: [
                 status: "completed",
                 join_outcome: "success",
                 report_delivery_state: "pending",
                 completed_at: DateTime.utc_now()
               ]
             )

    assert Fanout.parent_projection(parent).phase == :inconsistent
    assert Fanout.pending_reports("alice", "corrupt-report-thread", %{channel: "test"}) == []
  end

  test "joined projection requires both durable selection and join events" do
    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{user_id: "alice", title: "Join integrity", objective: "Join integrity"},
               ["one", "two"]
             )

    Enum.each(children, &complete_legacy_child!/1)

    selected = select_fallback!(parent)
    assert Fanout.parent_projection(selected).phase == :joined

    fallback_event =
      AllbertAssist.Objectives.Event
      |> where(
        [event],
        event.objective_id == ^parent.id and event.kind == "fanout_report_selected"
      )
      |> Repo.one!()

    tampered_fallback_payload =
      fallback_event.payload
      |> Jason.decode!()
      |> Map.put("fallback_reason", "provider_failed")
      |> Jason.encode!()

    assert {1, _rows} =
             AllbertAssist.Objectives.Event
             |> where([event], event.id == ^fallback_event.id)
             |> Repo.update_all(set: [payload: tampered_fallback_payload])

    assert %{phase: :inconsistent, authoritatively_joined?: false} =
             Fanout.parent_projection(parent)

    assert {1, _rows} =
             AllbertAssist.Objectives.Event
             |> where([event], event.id == ^fallback_event.id)
             |> Repo.update_all(set: [payload: fallback_event.payload])

    assert Fanout.parent_projection(parent).phase == :joined

    assert {1, _rows} =
             AllbertAssist.Objectives.Event
             |> where(
               [event],
               event.objective_id == ^parent.id and event.kind == "fanout_report_selected"
             )
             |> Repo.delete_all()

    assert %{phase: :inconsistent, authoritatively_joined?: false} =
             Fanout.parent_projection(parent)

    assert {:ok, _missing_provenance_event} =
             Objectives.create_event(%{
               objective_id: parent.id,
               kind: "fanout_report_selected",
               payload: %{
                 source: "deterministic_fallback",
                 input_digest: selected.report_input_digest,
                 body_sha256:
                   :crypto.hash(:sha256, selected.report_body)
                   |> Base.encode16(case: :lower)
               }
             })

    assert %{phase: :inconsistent, authoritatively_joined?: false} =
             Fanout.parent_projection(parent)

    assert {1, _rows} =
             AllbertAssist.Objectives.Event
             |> where(
               [event],
               event.objective_id == ^parent.id and event.kind == "fanout_report_selected"
             )
             |> Repo.delete_all()

    assert {:ok, persisted_parent} = Objectives.get_objective(parent.id)
    assert {:ok, v1_frozen} = Fanout.report_input_v1(persisted_parent)
    v1_provenance = %{fallback_reason: "model_disabled", layout_version: 1}

    assert {:ok, v1_selection_digest} =
             Report.selection_digest("deterministic_fallback", v1_provenance)

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(
               set: [
                 report_input_digest: v1_frozen.input_digest,
                 report_body: v1_frozen.fallback_body,
                 report_selection_digest: v1_selection_digest
               ]
             )

    joined_event =
      AllbertAssist.Objectives.Event
      |> where(
        [event],
        event.objective_id == ^parent.id and event.kind == "fanout_joined"
      )
      |> Repo.one!()

    v1_join_payload =
      joined_event.payload
      |> Jason.decode!()
      |> Map.put("report_input_digest", v1_frozen.input_digest)
      |> Jason.encode!()

    assert {1, _rows} =
             AllbertAssist.Objectives.Event
             |> where([event], event.id == ^joined_event.id)
             |> Repo.update_all(set: [payload: v1_join_payload])

    assert {:ok, _selection_event} =
             Objectives.create_event(%{
               objective_id: parent.id,
               kind: "fanout_report_selected",
               payload: %{
                 source: "deterministic_fallback",
                 fallback_reason: "model_disabled",
                 layout_version: 1,
                 input_digest: v1_frozen.input_digest,
                 body_sha256:
                   :crypto.hash(:sha256, v1_frozen.fallback_body)
                   |> Base.encode16(case: :lower)
               }
             })

    assert Fanout.parent_projection(parent).phase == :joined

    assert {1, _rows} =
             AllbertAssist.Objectives.Event
             |> where([event], event.objective_id == ^parent.id and event.kind == "fanout_joined")
             |> Repo.delete_all()

    assert %{phase: :inconsistent, authoritatively_joined?: false} =
             Fanout.parent_projection(parent)
  end

  test "orphan terminal children project inconsistent without crashing" do
    parent_id = "fanout_missing_parent"

    for {id, position} <- [{"obj_orphan_one", 0}, {"obj_orphan_two", 1}] do
      assert {:ok, _child} =
               Objectives.create_objective(%{
                 id: id,
                 user_id: "alice",
                 title: id,
                 objective: id,
                 fanout_role: "child",
                 parent_objective_id: parent_id,
                 queue_position: position,
                 status: "completed",
                 completed_at: DateTime.utc_now()
               })
    end

    assert %{phase: :inconsistent, parent: nil, children_terminal?: true} =
             Fanout.parent_projection(parent_id)
  end

  test "generic objective updates cannot bypass fan-out terminal authority" do
    assert {:ok, %{parent: parent, children: [child, _sibling]}} =
             Fanout.frame(
               %{user_id: "alice", title: "Guard authority", objective: "Guard authority"},
               ["first", "second"]
             )

    assert {:error, :fanout_active_transition_required} =
             Objectives.update_objective(child, %{status: "completed"})

    assert {:error, :fanout_parent_transition_required} =
             Objectives.update_objective(parent, %{
               status: "completed",
               join_outcome: "success",
               report_delivery_state: "pending"
             })

    assert {:error, :fanout_active_transition_required} =
             Objectives.update_objective(child, %{status: "running"})

    for attrs <- [
          %{title: "mutated title"},
          %{objective: "mutated objective"},
          %{acceptance_criteria: %{"summary" => "mutated result"}},
          %{constraints: "mutated constraints"},
          %{source_intent: "mutated source"}
        ] do
      assert {:error, :fanout_structure_immutable} =
               Objectives.update_objective(child, attrs)
    end

    assert {:ok, %{status: "running"}} =
             TerminalTransitions.transition_active_child(
               child,
               %{status: "running"},
               "run_started",
               %{attempt: 1}
             )
  end

  test "a stale active struct cannot reopen a terminal child" do
    assert {:ok, %{parent: parent, children: [stale, sibling]}} =
             Fanout.frame(
               %{user_id: "alice", title: "Race guard", objective: "Race guard"},
               ["first", "second"]
             )

    assert %{child: %{status: "completed"}} = complete_legacy_child!(stale)

    assert {:error, {:fanout_active_compare_and_set_failed, "completed"}} =
             Objectives.update_objective(stale, %{progress_summary: "stale writer"})

    assert {:error, {:active_transition_compare_and_set_failed, "completed"}} =
             TerminalTransitions.transition_active_child(
               stale,
               %{status: "running"},
               "run_started",
               %{attempt: 2}
             )

    assert %{child: %{status: "completed"}} = complete_legacy_child!(sibling)

    assert {:ok, %{status: "completed"}} = Objectives.get_objective(stale.id)

    assert {:ok, %{status: "completed", join_outcome: "success"}} =
             Objectives.get_objective(parent.id)

    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "unique receipt digests and fanout value domains are enforced" do
    attrs = %{user_id: "alice", title: "One", objective: "One", fanout_role: "parent"}

    assert {:ok, _first} =
             Objectives.create_objective(Map.put(attrs, :fanout_start_receipt_digest, "same"))

    assert {:error, changeset} =
             Objectives.create_objective(Map.put(attrs, :fanout_start_receipt_digest, "same"))

    assert "has already been taken" in errors_on(changeset).fanout_start_receipt_digest

    assert {:error, invalid} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Invalid",
               objective: "Invalid",
               fanout_role: "parent",
               kickoff_delivery_state: "sent"
             })

    assert "is invalid" in errors_on(invalid).kickoff_delivery_state
  end

  defp select_fallback!(parent) do
    assert {:ok, claim} = Fanout.claim_next_composition()
    assert claim.parent.id == parent.id

    assert {:ok, provenance} =
             Report.fallback_provenance(claim.frozen.snapshot, "model_disabled")

    assert {:ok, selected} =
             Fanout.select_composition(
               claim,
               "deterministic_fallback",
               claim.frozen.fallback_body,
               provenance
             )

    selected
  end

  defp report_parent(id, title, join_outcome) do
    %Objective{
      id: id,
      title: title,
      objective: "Join every terminal child into one truthful report",
      fanout_role: "parent",
      status: "completed",
      join_outcome: join_outcome
    }
  end

  defp report_child(position, title, objective, status, detail) do
    base = %Objective{
      id: "obj-report-#{position}",
      queue_position: position,
      title: title,
      objective: objective,
      fanout_role: "child",
      status: status
    }

    if status == "completed" do
      %{base | last_observation_summary: detail}
    else
      %{base | review_reason: detail}
    end
  end

  defp over_bound_report_fixture do
    parent = report_parent("fanout_report_over_bound", "Bounded sixteen-child report", "success")

    children =
      Enum.map(0..15, fn position ->
        detail =
          if rem(position, 2) == 0 do
            "unicode-#{position}-" <> String.duplicate("界", 1_900) <> "-unicode-tail-#{position}"
          else
            "unbroken-#{position}-" <>
              String.duplicate(Integer.to_string(rem(position, 10)), 1_900) <>
              "-unbroken-tail-#{position}"
          end

        %Objective{
          id: "obj-overflow-#{String.pad_leading(Integer.to_string(position), 2, "0")}",
          queue_position: position,
          title: "Overflow child #{String.pad_leading(Integer.to_string(position), 2, "0")}",
          objective: "Preserve bounded result #{position}",
          fanout_role: "child",
          status: "completed",
          last_observation_summary: detail
        }
      end)

    evidence_refs =
      Map.new(children, fn child ->
        {child.id,
         %{
           kind: "objective_step_trace",
           action: "inspect_overflow_#{child.queue_position}",
           trace_id: "trace-overflow-#{child.queue_position}"
         }}
      end)

    selection = %{
      "sections" => [
        %{
          "relationship" => "complementary",
          "ordered_queue_positions" => Enum.to_list(0..15)
        }
      ]
    }

    {parent, children, evidence_refs, selection}
  end

  defp assert_occurs_once(body, text), do: assert(occurrence_count(body, text) == 1)

  defp occurrence_count(body, text), do: body |> :binary.matches(text) |> length()

  defp overflow_detail_prefix(position) when rem(position, 2) == 0,
    do: "unicode-#{position}-"

  defp overflow_detail_prefix(position), do: "unbroken-#{position}-"

  defp assert_ordered(body, fragments) do
    positions =
      Enum.map(fragments, fn fragment ->
        {position, _length} = :binary.match(body, fragment)
        position
      end)

    assert positions == Enum.sort(positions)
  end

  defp queued_parent!(title) do
    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(%{user_id: "alice", title: title, objective: title}, [
               "first",
               "second"
             ])

    Enum.each(children, &complete_legacy_child!/1)

    assert {:ok, queued} = Objectives.get_objective(parent.id)
    assert queued.report_composition_state == "queued"
    queued
  end

  defp complete_legacy_child!(child, summary \\ nil) do
    summary = summary || "result #{child.queue_position}"

    assert {:ok, transition} =
             TerminalTransitions.terminalize_child(
               child,
               %{
                 status: "completed",
                 last_observation_summary: summary,
                 completed_at: DateTime.utc_now()
               },
               "run_completed",
               %{summary: String.slice(summary, 0, 500)}
             )

    transition
  end

  defp complete_action_child!(child, step) do
    summary = step.result_summary
    assert is_binary(summary)

    assert {:ok, transition} =
             TerminalTransitions.terminalize_child(
               child,
               %{
                 status: "completed",
                 current_step_id: step.id,
                 last_observation_summary: summary,
                 completed_at: DateTime.utc_now()
               },
               "run_completed",
               %{
                 summary: String.slice(summary, 0, 500),
                 step_id: step.id,
                 step_status: "completed"
               }
             )

    transition
  end

  defp record_legacy_completion_events!(children, summary) do
    Enum.each(children, fn child ->
      assert {:ok, _event} =
               Objectives.create_event(%{
                 objective_id: child.id,
                 kind: "run_completed",
                 payload: %{summary: String.slice(summary, 0, 500)}
               })
    end)
  end

  defp accepted_synthesis_result(synthesis) do
    %{
      "sections" => [
        %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
      ],
      "advisory_synthesis" => synthesis,
      "validation" => %{
        "outcome" => "passed",
        "covered_queue_positions" => [0, 1]
      }
    }
  end

  defp selection_payload(parent_id) do
    parent_id
    |> Objectives.list_events()
    |> Enum.find(&(&1.kind == "fanout_report_selected"))
    |> Map.fetch!(:payload)
    |> Jason.decode!()
  end

  defp assert_frozen_step_sql(statement, params) do
    assert {:error, error} = SQL.query(Repo, statement, params)
    assert Exception.message(error) =~ "fanout report input is frozen"
  end

  defp assert_frozen_child_sql(statement, params) do
    assert {:error, error} = SQL.query(Repo, statement, params)
    assert Exception.message(error) =~ "fanout report child snapshot is frozen"
  end

  defp assert_frozen_parent_sql(statement, params) do
    assert {:error, error} = SQL.query(Repo, statement, params)
    assert Exception.message(error) =~ "fanout report parent input is frozen"
  end
end
