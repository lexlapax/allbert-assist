defmodule AllbertAssist.Objectives.Fanout.TerminalTransitions do
  @moduledoc """
  Atomic terminal authority for fan-out children and their parent reduction.

  This plain module owns no process state. It starts an immediate SQLite
  transaction, conditionally terminalizes one active child, records its event,
  and closes the parent in the same commit when every sibling is terminal.
  Signals are emitted only after commit and remain advisory projections.
  """

  import Ecto.Query

  require Logger

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Event
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.Report
  alias AllbertAssist.Objectives.Fanout.ReportComposer
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Repo
  alias AllbertAssist.Signals

  @active ~w[open running blocked]
  @terminal ~w[completed cancelled failed abandoned]
  @composition_scan_batch_size 100
  @active_fields ~w[
    status title objective progress_summary last_observation_summary review_reason
    current_step_id run_attempt_count loop_count
  ]a
  @terminal_fields ~w[
    status progress_summary last_observation_summary review_reason completed_at current_step_id
  ]a

  @type join_result ::
          :not_terminal
          | {:joined_now, Objective.t()}
          | {:already_joined, Objective.t()}

  @type transition :: %{child: Objective.t(), join: join_result()}

  @type composition_claim :: %{
          parent: Objective.t(),
          frozen: Report.frozen(),
          deadline_unix_ms: integer() | nil,
          budget: map(),
          context: map()
        }

  @doc """
  Terminalize one fan-out child and reduce its parent in the same transaction.

  The optional signal is emitted after commit, before a newly joined parent
  signal, preserving the operator-visible child-terminal then fan-in order.
  """
  @spec terminalize_child(Objective.t(), map(), String.t(), map(), keyword()) ::
          {:ok, transition()} | {:error, term()}
  def terminalize_child(child, attrs, event_kind, event_payload, opts \\ [])

  def terminalize_child(
        %Objective{fanout_role: "child", parent_objective_id: parent_id} = child,
        attrs,
        event_kind,
        event_payload,
        opts
      )
      when is_binary(parent_id) and is_map(attrs) and is_binary(event_kind) and
             is_map(event_payload) and is_list(opts) do
    with {:ok, changes} <- validated_terminal_changes(child, attrs) do
      transaction = fn ->
        terminalize_transaction(child, changes, event_kind, event_payload, opts)
      end

      case Repo.transaction(transaction, mode: :immediate) do
        {:ok, transition} ->
          publish_transition(transition, Keyword.get(opts, :signal))
          {:ok, transition}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def terminalize_child(%Objective{}, _attrs, _event_kind, _event_payload, _opts),
    do: {:error, :not_fanout_child}

  @doc "Compare-and-set one active fan-out child transition and its event."
  @spec transition_active_child(Objective.t(), map(), String.t(), map(), keyword()) ::
          {:ok, Objective.t()} | {:error, term()}
  def transition_active_child(child, attrs, event_kind, event_payload, opts \\ [])

  def transition_active_child(
        %Objective{fanout_role: "child", parent_objective_id: parent_id} = child,
        attrs,
        event_kind,
        event_payload,
        opts
      )
      when is_binary(parent_id) and is_map(attrs) and is_binary(event_kind) and
             is_map(event_payload) and is_list(opts) do
    with {:ok, changes} <- validated_active_changes(child, attrs),
         {:ok, updated} <-
           Repo.transaction(
             fn ->
               active_transition_transaction(child, changes, event_kind, event_payload, opts)
             end,
             mode: :immediate
           ) do
      publish_child_signal(updated, Keyword.get(opts, :signal))
      {:ok, updated}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def transition_active_child(%Objective{}, _attrs, _event_kind, _event_payload, _opts),
    do: {:error, :not_fanout_child}

  @doc "Reconcile one parent idempotently from durable child state."
  @spec reconcile_parent(String.t(), keyword()) ::
          {:ok, join_result()} | {:error, term()}
  def reconcile_parent(parent_id, opts \\ [])
      when is_binary(parent_id) and is_list(opts) do
    recovered? = Keyword.get(opts, :recovered?, true)

    transaction = fn ->
      payload = if recovered?, do: %{recovered: true}, else: %{}
      reduce_parent(parent_id, DateTime.utc_now(), payload)
    end

    case Repo.transaction(transaction, mode: :immediate) do
      {:ok, result} ->
        enqueue_composition(result)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Compare-and-set the oldest queued parent into composer ownership."
  @spec claim_next_composition() :: {:ok, composition_claim()} | :none | {:error, term()}
  def claim_next_composition do
    case Repo.transaction(&claim_next_composition_transaction/0, mode: :immediate) do
      {:ok, :none} -> :none
      {:ok, claim} -> {:ok, claim}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Select one bounded report and open its existing delivery outbox."
  @spec select_composition(composition_claim(), String.t(), String.t(), map()) ::
          {:ok, Objective.t()} | {:error, term()}
  def select_composition(%{parent: parent, frozen: frozen}, source, body, provenance)
      when is_binary(source) and is_binary(body) and is_map(provenance) do
    with :ok <- Report.verify(frozen, parent.report_input_digest),
         {:ok, event_provenance} <- Report.normalize_selection_provenance(source, provenance),
         {:ok, selection_digest} <- Report.selection_digest(source, event_provenance),
         :ok <-
           Report.validate_selected_body(frozen.snapshot, source, body, event_provenance),
         {:ok, selected} <-
           select_composition_transaction(
             parent,
             frozen,
             source,
             body,
             event_provenance,
             selection_digest
           ) do
      publish_join(selected, %{report_source: source})
      {:ok, selected}
    end
  end

  def select_composition(_claim, _source, _body, _provenance),
    do: {:error, :invalid_fanout_report_selection}

  @doc "Resolve stranded composing and legacy selected-report rows deterministically."
  @spec recover_composition() :: {:ok, non_neg_integer()} | {:error, term()}
  def recover_composition, do: recover_composition_batches(nil, 0)

  defp recover_composition_batches(cursor, recovered_total) do
    case Fanout.composition_work_batch(cursor) do
      {:done, parents} ->
        recover_final_composition_batch(parents, recovered_total)

      {:more, parents, next_cursor} ->
        case recover_composition_batch(parents) do
          {:ok, recovered, integrity_failures} ->
            log_skipped_integrity_failures(integrity_failures)
            recover_composition_batches(next_cursor, recovered_total + recovered)

          {:error, reason, integrity_failures} ->
            log_skipped_integrity_failures(integrity_failures)
            {:error, reason}
        end
    end
  end

  defp recover_final_composition_batch(parents, recovered_total) do
    case recover_composition_batch(parents) do
      {:ok, recovered, integrity_failures} ->
        log_skipped_integrity_failures(integrity_failures)
        {:ok, recovered_total + recovered}

      {:error, reason, integrity_failures} ->
        log_skipped_integrity_failures(integrity_failures)
        {:error, reason}
    end
  end

  defp recover_composition_batch(parents) do
    Enum.reduce_while(parents, {:ok, 0, []}, &recover_composition_step/2)
  end

  defp claim_next_composition_transaction do
    case oldest_valid_queued_parent() do
      :none -> :none
      {:ok, parent, selection_input} -> claim_queued_composition(parent, selection_input)
    end
  end

  defp claim_queued_composition(parent, %{frozen: frozen} = selection_input) do
    now = DateTime.utc_now()

    case Repo.update_all(composition_claim_query(parent, selection_input),
           set: [
             report_composition_state: "composing",
             report_input_digest: frozen.input_digest,
             updated_at: now
           ]
         ) do
      {1, _rows} ->
        parent
        |> then(&Repo.get!(Objective, &1.id))
        |> composition_claim(frozen)

      {0, _rows} ->
        Repo.rollback(:stale_composition_claim)
    end
  end

  defp composition_claim_query(parent, selection_input) do
    expected_digest = selection_input.rebind_from || parent.report_input_digest

    Objective
    |> where([objective], objective.id == ^parent.id)
    |> where([objective], objective.fanout_role == "parent")
    |> where([objective], objective.report_composition_state == "queued")
    |> where([objective], objective.report_delivery_state == "not_ready")
    |> where([objective], objective.report_input_digest == ^expected_digest)
    |> where([objective], is_nil(objective.report_selection_digest))
    |> where([objective], is_nil(objective.report_body))
    |> where([objective], is_nil(objective.report_source))
    |> where([objective], is_nil(objective.report_delivery_receipt_digest))
  end

  defp recover_composition_step(parent, {:ok, count, integrity_failures}) do
    parent
    |> recover_composition_parent()
    |> recover_composition_result(parent, count, integrity_failures)
  end

  defp recover_composition_result(:queued, _parent, count, integrity_failures),
    do: {:cont, {:ok, count, integrity_failures}}

  defp recover_composition_result({:ok, :recovered}, _parent, count, integrity_failures),
    do: {:cont, {:ok, count + 1, integrity_failures}}

  defp recover_composition_result({:error, reason}, parent, count, integrity_failures) do
    if composition_integrity_failure?(reason) do
      {:cont, {:ok, count, [{parent.id, reason} | integrity_failures]}}
    else
      {:halt, {:error, reason, integrity_failures}}
    end
  end

  defp validated_terminal_changes(child, attrs) do
    attrs = Map.take(attrs, @terminal_fields)
    status = Map.get(attrs, :status) || Map.get(attrs, "status")

    if status in @terminal do
      changeset = Objective.changeset(child, attrs)

      if changeset.valid?,
        do: {:ok, changeset.changes},
        else: {:error, changeset}
    else
      {:error, {:invalid_terminal_status, status}}
    end
  end

  defp validated_active_changes(child, attrs) do
    attrs = Map.take(attrs, @active_fields)
    status = Map.get(attrs, :status) || Map.get(attrs, "status")

    if status in @active do
      changeset = Objective.changeset(child, attrs)

      if changeset.valid?,
        do: {:ok, changeset.changes},
        else: {:error, changeset}
    else
      {:error, {:invalid_active_status, status}}
    end
  end

  defp terminalize_transaction(child, changes, event_kind, event_payload, opts) do
    now = DateTime.utc_now()

    if pending_steering?(child.id) and
         event_kind not in ["cancelled", "run_cancelled", "run_abandoned"] do
      Repo.rollback(:pending_steering_directive)
    end

    query =
      from objective in Objective,
        where:
          objective.id == ^child.id and objective.fanout_role == "child" and
            objective.parent_objective_id == ^child.parent_objective_id and
            objective.status in ^@active

    query = maybe_require_stale_snapshot(query, Keyword.get(opts, :updated_before))

    updates = changes |> Map.put(:updated_at, now) |> Map.to_list()

    case Repo.update_all(query, set: updates) do
      {1, _rows} ->
        updated = Repo.get!(Objective, child.id)
        transaction_payload = run_transaction_hook(updated, opts)
        record_event!(updated.id, event_kind, Map.merge(event_payload, transaction_payload))
        %{child: updated, join: reduce_parent(updated.parent_objective_id, now)}

      {0, _rows} ->
        current = Repo.get(Objective, child.id)
        Repo.rollback({:objective_not_terminalizable, current && current.status})
    end
  end

  defp active_transition_transaction(child, changes, event_kind, event_payload, opts) do
    now = DateTime.utc_now()
    from_statuses = Keyword.get(opts, :from, @active)

    query =
      from objective in Objective,
        where:
          objective.id == ^child.id and objective.fanout_role == "child" and
            objective.parent_objective_id == ^child.parent_objective_id and
            objective.status in ^from_statuses and objective.updated_at == ^child.updated_at

    updates = changes |> Map.put(:updated_at, now) |> Map.to_list()

    case Repo.update_all(query, set: updates) do
      {1, _rows} ->
        updated = Repo.get!(Objective, child.id)
        transaction_payload = run_transaction_hook(updated, opts)
        record_event!(updated.id, event_kind, Map.merge(event_payload, transaction_payload))
        updated

      {0, _rows} ->
        current = Repo.get(Objective, child.id)
        Repo.rollback({:active_transition_compare_and_set_failed, current && current.status})
    end
  end

  defp maybe_require_stale_snapshot(query, nil), do: query

  defp maybe_require_stale_snapshot(query, %DateTime{} = cutoff) do
    where(query, [objective], objective.updated_at < ^cutoff)
  end

  defp run_transaction_hook(child, opts) do
    case Keyword.get(opts, :transaction_hook) do
      nil ->
        %{}

      hook when is_function(hook, 1) ->
        case hook.(child) do
          :ok -> %{}
          {:ok, payload} when is_map(payload) -> payload
          payload when is_map(payload) -> payload
          {:error, reason} -> Repo.rollback(reason)
          other -> Repo.rollback({:invalid_terminal_transaction_hook_result, other})
        end
    end
  end

  defp reduce_parent(parent_id, now, join_payload \\ %{}) do
    parent = Repo.get(Objective, parent_id)
    join = Fanout.join_status(parent_id)
    reduce_parent_state(parent, join, parent_id, now, join_payload)
  end

  defp reduce_parent_state(
         %Objective{fanout_role: "parent", report_delivery_state: "not_ready"},
         %{terminal?: true, status: status, outcome: outcome},
         parent_id,
         now,
         join_payload
       ) do
    reduce_terminal_parent(parent_id, status, outcome, now, join_payload)
  end

  defp reduce_parent_state(
         %Objective{fanout_role: "parent", report_composition_state: state} = parent,
         _join,
         _parent_id,
         _now,
         _join_payload
       )
       when state in ["queued", "composing", "ready", "fallback"],
       do: {:already_joined, parent}

  defp reduce_parent_state(
         %Objective{fanout_role: "parent", report_delivery_state: state} = parent,
         _join,
         _parent_id,
         _now,
         _join_payload
       )
       when state in ["pending", "delivered"],
       do: {:already_joined, parent}

  defp reduce_parent_state(
         %Objective{fanout_role: "parent"},
         _join,
         _parent_id,
         _now,
         _join_payload
       ),
       do: :not_terminal

  defp reduce_parent_state(_parent, _join, _parent_id, _now, _join_payload),
    do: Repo.rollback(:fanout_parent_not_found)

  defp reduce_terminal_parent(parent_id, status, outcome, now, join_payload) do
    parent = Repo.get!(Objective, parent_id)
    reduced_parent = %{parent | status: status, join_outcome: outcome}
    frozen = freeze_reduced_parent(reduced_parent)

    updates = [
      status: status,
      join_outcome: outcome,
      report_composition_state: "queued",
      report_input_digest: frozen.input_digest,
      completed_at: now,
      updated_at: now
    ]

    case Repo.update_all(reduce_parent_query(parent_id), set: updates) do
      {1, _rows} ->
        record_join(parent_id, status, outcome, frozen.input_digest, join_payload)

      {0, _rows} ->
        already_joined(parent_id)
    end
  end

  defp freeze_reduced_parent(parent) do
    case Fanout.report_input(parent) do
      {:ok, frozen} -> frozen
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp reduce_parent_query(parent_id) do
    from parent in Objective,
      where:
        parent.id == ^parent_id and parent.fanout_role == "parent" and
          parent.report_delivery_state == "not_ready" and
          parent.report_composition_state == "not_ready"
  end

  defp record_join(parent_id, status, outcome, input_digest, join_payload) do
    joined = Repo.get!(Objective, parent_id)

    record_event!(
      joined.id,
      "fanout_joined",
      Map.merge(join_payload, %{
        status: status,
        join_outcome: outcome,
        report_composition_state: "queued",
        report_input_digest: input_digest
      })
    )

    {:joined_now, joined}
  end

  defp already_joined(parent_id) do
    case Repo.get(Objective, parent_id) do
      %Objective{fanout_role: "parent", report_composition_state: state} = parent
      when state in ["queued", "composing", "ready", "fallback"] ->
        {:already_joined, parent}

      %Objective{fanout_role: "parent", report_delivery_state: state} = parent
      when state in ["pending", "delivered"] ->
        {:already_joined, parent}

      _other ->
        Repo.rollback(:fanout_join_compare_and_set_failed)
    end
  end

  defp record_event!(objective_id, kind, payload) do
    case Objectives.create_event(%{objective_id: objective_id, kind: kind, payload: payload}) do
      {:ok, _event} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp oldest_valid_queued_parent, do: scan_queued_parents(nil)

  defp scan_queued_parents(cursor) do
    parents = queued_parent_batch(cursor)

    case scan_queued_batch(parents) do
      {:ok, parent, selection_input, integrity_failures} ->
        log_skipped_integrity_failures(integrity_failures)
        {:ok, parent, selection_input}

      {:none, integrity_failures} ->
        log_skipped_integrity_failures(integrity_failures)

        if length(parents) < @composition_scan_batch_size do
          :none
        else
          last = List.last(parents)
          scan_queued_parents({last.completed_at, last.id})
        end
    end
  end

  defp queued_parent_batch(cursor) do
    Objective
    |> where(
      [objective],
      objective.fanout_role == "parent" and objective.report_composition_state == "queued" and
        objective.report_delivery_state == "not_ready"
    )
    |> after_composition_cursor(cursor)
    |> order_by([objective], asc: objective.completed_at, asc: objective.id)
    |> limit(@composition_scan_batch_size)
    |> Repo.all()
  end

  defp after_composition_cursor(query, nil), do: query

  defp after_composition_cursor(query, {nil, id}) do
    where(
      query,
      [objective],
      (is_nil(objective.completed_at) and objective.id > ^id) or
        not is_nil(objective.completed_at)
    )
  end

  defp after_composition_cursor(query, {completed_at, id}) do
    where(
      query,
      [objective],
      objective.completed_at > ^completed_at or
        (objective.completed_at == ^completed_at and objective.id > ^id)
    )
  end

  defp scan_queued_batch(parents) do
    Enum.reduce_while(parents, {:none, []}, fn parent, {_result, integrity_failures} ->
      parent
      |> Fanout.report_input_for_selection()
      |> scan_queued_result(parent, integrity_failures)
    end)
  end

  defp scan_queued_result({:ok, selection_input}, parent, integrity_failures),
    do: {:halt, {:ok, parent, selection_input, integrity_failures}}

  defp scan_queued_result({:error, reason}, parent, integrity_failures) do
    if composition_integrity_failure?(reason) do
      {:cont, {:none, [{parent.id, reason} | integrity_failures]}}
    else
      Repo.rollback(reason)
    end
  end

  defp log_skipped_integrity_failures([]), do: :ok

  defp log_skipped_integrity_failures(failures) do
    {reason_order, parent_ids_by_reason} =
      failures
      |> Enum.reverse()
      |> Enum.reduce({[], %{}}, fn {parent_id, reason}, {reason_order, grouped} ->
        if Map.has_key?(grouped, reason) do
          {reason_order, Map.update!(grouped, reason, &[parent_id | &1])}
        else
          {[reason | reason_order], Map.put(grouped, reason, [parent_id])}
        end
      end)

    reason_order
    |> Enum.reverse()
    |> Enum.each(fn reason ->
      parent_ids = parent_ids_by_reason |> Map.fetch!(reason) |> Enum.reverse()

      Logger.error(
        "fan-out report composition skipped frozen-input integrity failures " <>
          "reason=#{inspect(reason)} count=#{length(parent_ids)} " <>
          "first_parent_id=#{List.first(parent_ids)} " <>
          "last_parent_id=#{List.last(parent_ids)} " <>
          "parent_ids=#{Enum.join(parent_ids, ",")}"
      )
    end)
  end

  defp composition_claim(parent, frozen) do
    plan = frozen.snapshot.plan

    %{
      parent: parent,
      frozen: frozen,
      deadline_unix_ms: Map.get(plan, "deadline_unix_ms"),
      budget: Map.get(plan, "budget") || %{},
      context: %{
        user_id: parent.user_id,
        thread_id: parent.source_thread_id,
        channel: parent.source_channel,
        surface: parent.source_surface,
        session_id: parent.session_id,
        active_app: parent.active_app
      }
    }
  end

  defp select_composition_transaction(
         parent,
         frozen,
         source,
         body,
         event_provenance,
         selection_digest
       ) do
    state = if source == "model", do: "ready", else: "fallback"
    receipt = Fanout.receipt_for(:report, parent.id)
    now = DateTime.utc_now()

    selection = %{
      parent: parent,
      frozen: frozen,
      source: source,
      body: body,
      event_provenance: event_provenance,
      selection_digest: selection_digest,
      state: state,
      receipt: receipt,
      now: now
    }

    case Repo.transaction(fn -> persist_selected_composition(selection) end, mode: :immediate) do
      {:ok, selected} -> {:ok, selected}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_selected_composition(%{
         parent: parent,
         frozen: frozen,
         source: source,
         body: body,
         event_provenance: event_provenance,
         selection_digest: selection_digest,
         state: state,
         receipt: receipt,
         now: now
       }) do
    updates = [
      report_composition_state: state,
      report_body: body,
      report_source: source,
      report_selection_digest: selection_digest,
      report_delivery_state: "pending",
      report_delivery_receipt_digest: receipt_digest(receipt),
      updated_at: now
    ]

    case Repo.update_all(composition_selection_query(parent, frozen), set: updates) do
      {1, _rows} ->
        record_composition_selection(parent, frozen, source, body, event_provenance)

      {0, _rows} ->
        Repo.rollback(:stale_composition_claim)
    end
  end

  defp composition_selection_query(parent, frozen) do
    from objective in Objective,
      where:
        objective.id == ^parent.id and objective.fanout_role == "parent" and
          objective.report_composition_state == "composing" and
          objective.report_delivery_state == "not_ready" and
          objective.report_input_digest == ^frozen.input_digest and
          is_nil(objective.report_selection_digest) and
          is_nil(objective.report_delivery_receipt_digest)
  end

  defp record_composition_selection(parent, frozen, source, body, event_provenance) do
    selected = Repo.get!(Objective, parent.id)

    event_payload =
      Map.merge(event_provenance, %{
        source: source,
        input_digest: frozen.input_digest,
        body_sha256: receipt_digest(body)
      })

    record_event!(selected.id, "fanout_report_selected", event_payload)
    selected
  end

  defp recover_composition_parent(%Objective{report_composition_state: "queued"}), do: :queued

  defp recover_composition_parent(%Objective{report_composition_state: "composing"} = parent) do
    with {:ok, selection_input} <- Fanout.report_input_for_selection(parent),
         {:ok, rebound_parent, frozen} <- rebind_composing_input(parent, selection_input),
         {:ok, provenance} <-
           Report.fallback_provenance(frozen.snapshot, "recovery_after_restart"),
         {:ok, _selected} <-
           select_composition(
             composition_claim(rebound_parent, frozen),
             "deterministic_fallback",
             frozen.fallback_body,
             provenance
           ) do
      {:ok, :recovered}
    end
  end

  defp recover_composition_parent(
         %Objective{
           report_composition_state: "not_ready",
           report_delivery_state: state
         } = parent
       )
       when state in ["pending", "delivered"] do
    with :ok <- validate_legacy_report_receipt(parent),
         {:ok, frozen} <- Fanout.report_input_v1(parent),
         :ok <- verify_historical_report_input(parent, frozen),
         {:ok, selected} <- backfill_legacy_report(parent, frozen) do
      if state == "pending" do
        publish_join(selected, %{historical_backfill: true, report_source: selected.report_source})
      end

      {:ok, :recovered}
    end
  end

  defp recover_composition_parent(_parent), do: :queued

  defp rebind_composing_input(parent, %{frozen: frozen, rebind_from: nil}),
    do: {:ok, parent, frozen}

  defp rebind_composing_input(parent, %{frozen: frozen, rebind_from: old_digest}) do
    transaction = fn -> rebind_composing_transaction(parent, frozen, old_digest) end

    case Repo.transaction(transaction, mode: :immediate) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp rebind_composing_transaction(parent, frozen, old_digest) do
    query = rebind_composing_query(parent, old_digest)

    case Repo.update_all(query,
           set: [report_input_digest: frozen.input_digest, updated_at: DateTime.utc_now()]
         ) do
      {1, _rows} -> {:ok, Repo.get!(Objective, parent.id), frozen}
      {0, _rows} -> Repo.rollback(:stale_composition_claim)
    end
  end

  defp rebind_composing_query(parent, old_digest) do
    Objective
    |> where([objective], objective.id == ^parent.id)
    |> where([objective], objective.fanout_role == "parent")
    |> where([objective], objective.report_composition_state == "composing")
    |> where([objective], objective.report_delivery_state == "not_ready")
    |> where([objective], objective.report_input_digest == ^old_digest)
    |> where([objective], is_nil(objective.report_selection_digest))
    |> where([objective], is_nil(objective.report_body))
    |> where([objective], is_nil(objective.report_source))
    |> where([objective], is_nil(objective.report_delivery_receipt_digest))
  end

  defp validate_legacy_report_receipt(%Objective{report_delivery_receipt_digest: digest})
       when is_binary(digest),
       do: :ok

  defp validate_legacy_report_receipt(_parent),
    do: {:error, :fanout_report_legacy_receipt_invalid}

  defp verify_historical_report_input(%Objective{report_input_digest: nil}, _frozen), do: :ok

  defp verify_historical_report_input(%Objective{report_input_digest: digest}, frozen),
    do: Report.verify(frozen, digest)

  defp composition_integrity_failure?(reason)
       when reason in [
              :fanout_report_input_mismatch,
              :invalid_fanout_report_input,
              :invalid_fanout_report_parent,
              :fanout_report_children_required,
              :fanout_report_child_limit_exceeded,
              :invalid_fanout_report_child,
              :fanout_report_children_not_terminal,
              :invalid_fanout_report_child_position,
              :duplicate_fanout_report_child_position,
              :fanout_report_legacy_receipt_invalid,
              :invalid_fanout_report_child_authority,
              :invalid_fanout_report_quality_receipt,
              :missing_fanout_report_completion_event,
              :invalid_fanout_report_completion_event,
              :invalid_fanout_report_terminal_step,
              :invalid_fanout_report_registered_action
            ],
       do: true

  defp composition_integrity_failure?(_reason), do: false

  defp backfill_legacy_report(parent, frozen) do
    now = DateTime.utc_now()

    {:ok, event_provenance} =
      Report.fallback_provenance(frozen.snapshot, "historical_backfill")

    {:ok, selection_digest} =
      Report.selection_digest("deterministic_fallback", event_provenance)

    transaction = fn ->
      query =
        from objective in Objective,
          where:
            objective.id == ^parent.id and objective.fanout_role == "parent" and
              objective.report_composition_state == "not_ready" and
              objective.report_delivery_state == ^parent.report_delivery_state and
              not is_nil(objective.report_delivery_receipt_digest)

      updates = [
        report_composition_state: "fallback",
        report_body: frozen.fallback_body,
        report_source: "deterministic_fallback",
        report_input_digest: frozen.input_digest,
        report_selection_digest: selection_digest,
        updated_at: now
      ]

      case Repo.update_all(query, set: updates) do
        {1, _rows} ->
          selected = Repo.get!(Objective, parent.id)

          record_event!(
            selected.id,
            "fanout_report_selected",
            Map.merge(event_provenance, %{
              source: "deterministic_fallback",
              input_digest: frozen.input_digest,
              body_sha256: receipt_digest(frozen.fallback_body),
              historical_backfill: true
            })
          )

          selected

        {0, _rows} ->
          Repo.rollback(:stale_composition_claim)
      end
    end

    case Repo.transaction(transaction, mode: :immediate) do
      {:ok, selected} -> {:ok, selected}
      {:error, reason} -> {:error, reason}
    end
  end

  defp publish_transition(%{child: child, join: join}, signal) do
    publish_child_signal(child, signal)
    enqueue_composition(join)
    wake_coordinator(child)
  end

  defp enqueue_composition({:joined_now, %Objective{id: parent_id}}) do
    ReportComposer.enqueue(parent_id)
  end

  defp enqueue_composition(_other), do: :ok

  defp wake_coordinator(%Objective{parent_objective_id: parent_id, id: child_id}) do
    case Registry.lookup(AllbertAssist.Objectives.Runs.Registry, {:fanout, parent_id}) do
      [{pid, _value}] -> send(pid, {:durable_terminal, child_id})
      [] -> :ok
    end
  end

  defp publish_join(parent, extra) do
    Signals.emit_fanout(
      :fanout_joined,
      Map.merge(extra, %{
        parent_id: parent.id,
        status: parent.status,
        join_outcome: parent.join_outcome
      })
    )
  end

  defp publish_child_signal(_child, nil), do: :ok

  defp publish_child_signal(child, {kind, data}) when is_atom(kind) and is_map(data) do
    Signals.emit_fanout(
      kind,
      data
      |> Map.put_new(:child_id, child.id)
      |> Map.put_new(:parent_id, child.parent_objective_id)
    )
  end

  defp receipt_digest(value),
    do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  defp pending_steering?(child_id) do
    events =
      Event
      |> where(
        [event],
        event.objective_id == ^child_id and event.kind in ["steer_directive", "steer_applied"]
      )
      |> Repo.all()

    applied =
      events
      |> Enum.filter(&(&1.kind == "steer_applied"))
      |> MapSet.new(fn event -> event_payload(event)["directive_event_id"] end)

    Enum.any?(events, fn event ->
      event.kind == "steer_directive" and not MapSet.member?(applied, event.id)
    end)
  end

  defp event_payload(event) do
    case Jason.decode(event.payload || "{}") do
      {:ok, payload} -> payload
      _other -> %{}
    end
  end
end
