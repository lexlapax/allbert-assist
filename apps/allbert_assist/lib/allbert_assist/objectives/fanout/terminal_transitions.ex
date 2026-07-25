defmodule AllbertAssist.Objectives.Fanout.TerminalTransitions do
  @moduledoc """
  Atomic terminal authority for fan-out children and their parent reduction.

  This plain module owns no process state. It starts an immediate SQLite
  transaction, conditionally terminalizes one active child, records its event,
  and closes the parent in the same commit when every sibling is terminal.
  Signals are emitted only after commit and remain advisory projections.
  """

  import Ecto.Query

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Event
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Repo
  alias AllbertAssist.Signals

  @active ~w[open running blocked]
  @terminal ~w[completed cancelled failed abandoned]
  @active_fields ~w[
    status title objective progress_summary last_observation_summary review_reason
    current_step_id run_attempt_count proposer_hint loop_count
  ]a
  @terminal_fields ~w[status progress_summary last_observation_summary review_reason completed_at]a

  @type join_result ::
          :not_terminal
          | {:joined_now, Objective.t()}
          | {:already_joined, Objective.t()}

  @type transition :: %{child: Objective.t(), join: join_result()}

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
        publish_join(result, %{recovered: recovered?})
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
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
    case {Repo.get(Objective, parent_id), Fanout.join_status(parent_id)} do
      {%Objective{fanout_role: "parent", report_delivery_state: "not_ready"},
       %{terminal?: true, status: status, outcome: outcome}} ->
        receipt = Fanout.receipt_for(:report, parent_id)

        query =
          from parent in Objective,
            where:
              parent.id == ^parent_id and parent.fanout_role == "parent" and
                parent.report_delivery_state == "not_ready"

        updates = [
          status: status,
          join_outcome: outcome,
          report_delivery_state: "pending",
          report_delivery_receipt_digest: receipt_digest(receipt),
          completed_at: now,
          updated_at: now
        ]

        case Repo.update_all(query, set: updates) do
          {1, _rows} ->
            joined = Repo.get!(Objective, parent_id)

            record_event!(
              joined.id,
              "fanout_joined",
              Map.merge(join_payload, %{status: status, join_outcome: outcome})
            )

            {:joined_now, joined}

          {0, _rows} ->
            already_joined(parent_id)
        end

      {%Objective{fanout_role: "parent", report_delivery_state: state} = parent, _joined}
      when state in ["pending", "delivered"] ->
        {:already_joined, parent}

      {%Objective{fanout_role: "parent"}, _joined} ->
        :not_terminal

      _other ->
        Repo.rollback(:fanout_parent_not_found)
    end
  end

  defp already_joined(parent_id) do
    case Repo.get(Objective, parent_id) do
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

  defp publish_transition(%{child: child, join: join}, signal) do
    publish_child_signal(child, signal)
    publish_join(join, %{})
    wake_coordinator(child)
  end

  defp wake_coordinator(%Objective{parent_objective_id: parent_id, id: child_id}) do
    case Registry.lookup(AllbertAssist.Objectives.Runs.Registry, {:fanout, parent_id}) do
      [{pid, _value}] -> send(pid, {:durable_terminal, child_id})
      [] -> :ok
    end
  end

  defp publish_join({:joined_now, parent}, extra) do
    Signals.emit_fanout(
      :fanout_joined,
      Map.merge(extra, %{
        parent_id: parent.id,
        status: parent.status,
        join_outcome: parent.join_outcome
      })
    )
  end

  defp publish_join(_other, _extra), do: :ok

  defp publish_child_signal(_child, nil), do: :ok

  defp publish_child_signal(child, {kind, data}) when is_atom(kind) and is_map(data) do
    Signals.emit_fanout(
      kind,
      data
      |> Map.put_new(:child_id, child.id)
      |> Map.put_new(:parent_id, child.parent_objective_id)
    )
  end

  defp receipt_digest(receipt),
    do: Base.encode16(:crypto.hash(:sha256, receipt), case: :lower)

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
