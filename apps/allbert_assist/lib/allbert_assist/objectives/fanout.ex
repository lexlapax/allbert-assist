defmodule AllbertAssist.Objectives.Fanout do
  @moduledoc """
  Durable fan-out framing and honest terminal reduction.

  Framing is one database transaction. Receipt digests, not bearer receipts,
  are persisted; starting execution is deliberately outside this module.
  """

  import Ecto.Query

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout.ReceiptSecret
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime.Redactor

  @terminal ~w[completed cancelled failed abandoned]

  @spec frame(map(), [map() | String.t()]) :: {:ok, map()} | {:error, term()}
  def frame(parent_attrs, tasks) when is_map(parent_attrs) and is_list(tasks) do
    with :ok <- validate_tasks(tasks) do
      Repo.transaction(fn -> frame_transaction!(parent_attrs, tasks) end)
    end
  end

  @spec children(Objective.t() | String.t()) :: [Objective.t()]
  def children(%Objective{id: id}), do: children(id)

  def children(parent_id) when is_binary(parent_id) do
    Objective
    |> where([o], o.parent_objective_id == ^parent_id and o.fanout_role == "child")
    |> order_by([o], asc: o.queue_position, asc: o.inserted_at)
    |> Repo.all()
  end

  @doc "Return acknowledged fan-out parents eligible for executor reconciliation."
  @spec runnable_parents() :: [Objective.t()]
  def runnable_parents do
    Objective
    |> where(
      [o],
      o.fanout_role == "parent" and o.kickoff_delivery_state == "acknowledged" and
        o.status in ["open", "running", "blocked"]
    )
    |> order_by([o], asc: o.inserted_at, asc: o.id)
    |> Repo.all()
  end

  @doc "Return pending join reports without consuming their delivery receipts."
  @spec pending_reports(String.t(), String.t()) :: [map()]
  def pending_reports(user_id, thread_id) when is_binary(user_id) and is_binary(thread_id) do
    Objective
    |> where(
      [o],
      o.fanout_role == "parent" and o.user_id == ^user_id and
        o.source_thread_id == ^thread_id and o.report_delivery_state == "pending"
    )
    |> order_by([o], asc: o.completed_at, asc: o.id)
    |> Repo.all()
    |> Enum.map(fn parent ->
      %{
        parent_objective_id: parent.id,
        report: report(parent),
        report_delivery_receipt: receipt_for(:report, parent.id),
        delivery_context: receipt_delivery_context(parent)
      }
    end)
  end

  @spec join_status(Objective.t() | String.t()) :: %{
          terminal?: boolean(),
          status: String.t(),
          outcome: String.t() | nil
        }
  def join_status(parent) do
    children = children(parent)
    {status, outcome} = reduce(children)
    %{terminal?: Enum.all?(children, &(&1.status in @terminal)), status: status, outcome: outcome}
  end

  @type report :: %{
          parent_objective_id: String.t(),
          status: String.t(),
          join_outcome: String.t() | nil,
          children: [map()]
        }

  @spec report(Objective.t() | String.t()) :: report()
  def report(%Objective{id: id}), do: report(id)

  def report(parent_id) when is_binary(parent_id) do
    result = join_status(parent_id)

    Redactor.redact(%{
      parent_objective_id: parent_id,
      status: result.status,
      join_outcome: result.outcome,
      children:
        Enum.map(children(parent_id), fn child ->
          %{
            id: child.id,
            title: child.title,
            status: child.status,
            result_summary: child.last_observation_summary || child.progress_summary,
            review_reason: child.review_reason
          }
        end)
    })
  end

  @doc "Atomically records successful kickoff delivery. The receipt is single-use and identity-bound."
  @spec acknowledge_start(String.t(), map()) ::
          :ok | {:error, :invalid_receipt | :receipt_identity_mismatch}
  def acknowledge_start(receipt, context) when is_binary(receipt) and is_map(context) do
    case acknowledge_receipt(
           :fanout_start_receipt_digest,
           digest(receipt),
           :kickoff_delivery_state,
           "pending",
           "acknowledged",
           context
         ) do
      {:error, :receipt_identity_mismatch} ->
        acknowledge_receipt(
          :fanout_start_receipt_digest,
          digest(receipt),
          :kickoff_delivery_state,
          "blocked",
          "acknowledged",
          context
        )

      result ->
        result
    end
  end

  @doc "Mark a failed kickoff delivery as blocked without consuming its stable receipt."
  @spec mark_start_delivery_failed(String.t(), map()) ::
          :ok | {:error, :invalid_receipt | :receipt_identity_mismatch}
  def mark_start_delivery_failed(receipt, context)
      when is_binary(receipt) and is_map(context) do
    acknowledge_receipt(
      :fanout_start_receipt_digest,
      digest(receipt),
      :kickoff_delivery_state,
      "pending",
      "blocked",
      context
    )
  end

  @doc "Persists a terminal join and returns the report delivery receipt once."
  @spec finalize_join(Objective.t() | String.t()) :: {:ok, map()} | {:error, term()}
  def finalize_join(%Objective{id: id}), do: finalize_join(id)

  def finalize_join(parent_id) when is_binary(parent_id) do
    case Repo.transaction(fn -> finalize_join_transaction(parent_id) end) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finalize_join_transaction(parent_id) do
    case {Repo.get(Objective, parent_id), join_status(parent_id)} do
      {%Objective{fanout_role: "parent", report_delivery_state: "not_ready"} = parent,
       %{terminal?: true} = joined} ->
        receipt = receipt_for(:report, parent_id)

        attrs = %{
          status: joined.status,
          join_outcome: joined.outcome,
          report_delivery_state: "pending",
          report_delivery_receipt_digest: digest(receipt),
          completed_at: DateTime.utc_now()
        }

        case Objectives.update_objective(parent, attrs) do
          {:ok, updated} ->
            record_event!(updated.id, "fanout_joined", %{
              status: joined.status,
              join_outcome: joined.outcome
            })

            {:ok, %{parent: updated, report: report(updated), report_delivery_receipt: receipt}}

          error ->
            error
        end

      {%Objective{fanout_role: "parent"}, _joined} ->
        {:error, :fanout_not_terminal_or_already_finalized}

      _other ->
        {:error, :fanout_not_found}
    end
  end

  @doc "Atomically acknowledges a successfully delivered pending report."
  @spec acknowledge_report(String.t(), map()) ::
          :ok | {:error, :invalid_receipt | :receipt_identity_mismatch}
  def acknowledge_report(receipt, context) when is_binary(receipt) and is_map(context) do
    acknowledge_receipt(
      :report_delivery_receipt_digest,
      digest(receipt),
      :report_delivery_state,
      "pending",
      "delivered",
      context
    )
  end

  defp frame_transaction!(attrs, tasks) do
    parent_id = Map.get(attrs, :id) || Map.get(attrs, "id") || Objectives.new_id("fanout")
    receipt = receipt_for(:start, parent_id)

    parent_attrs =
      attrs
      |> Map.put(:id, parent_id)
      |> Map.put(:fanout_role, "parent")
      |> Map.put(:join_policy, "all_terminal")
      |> Map.put(:kickoff_delivery_state, "pending")
      |> Map.put(:fanout_start_receipt_digest, digest(receipt))
      |> Map.put(:report_delivery_state, "not_ready")

    parent = insert!(Objectives.create_objective(parent_attrs))

    children =
      tasks
      |> Enum.with_index()
      |> Enum.map(fn {task, position} ->
        task = normalize_task(task)

        parent_attrs
        |> Map.take([
          :user_id,
          :source_thread_id,
          :source_channel,
          :source_surface,
          :session_id,
          :active_app,
          :source_intent,
          :origin_thread_ref_id,
          :origin_thread_ref_digest,
          :origin_receiver_account_ref
        ])
        |> Map.merge(task)
        |> Map.put(:parent_objective_id, parent.id)
        |> Map.put(:fanout_role, "child")
        |> Map.put(:queue_position, position)
        |> Map.put(:kickoff_delivery_state, nil)
        |> Map.put(:fanout_start_receipt_digest, nil)
        |> Map.put(:report_delivery_state, "not_ready")
        |> Objectives.create_objective()
        |> insert!()
      end)

    insert!(
      Objectives.create_event(%{
        objective_id: parent.id,
        kind: "fanout_proposed",
        payload: %{child_ids: Enum.map(children, & &1.id), child_count: length(children)}
      })
    )

    %{parent: parent, children: children, fanout_start_receipt: receipt}
  end

  defp reduce([]), do: {"open", nil}

  defp reduce(children) do
    statuses = Enum.map(children, & &1.status)

    cond do
      Enum.all?(statuses, &(&1 == "completed")) ->
        {"completed", "success"}

      Enum.all?(statuses, &(&1 == "cancelled")) ->
        {"cancelled", "cancelled"}

      Enum.all?(statuses, &(&1 in @terminal)) and "completed" in statuses ->
        {"completed", "partial"}

      Enum.all?(statuses, &(&1 in @terminal)) and
          Enum.any?(statuses, &(&1 in ~w[failed abandoned])) ->
        {"failed", "failed"}

      true ->
        {"running", nil}
    end
  end

  defp validate_tasks(tasks) when length(tasks) >= 2, do: :ok
  defp validate_tasks(_tasks), do: {:error, :fanout_requires_at_least_two_children}

  defp normalize_task(task) when is_binary(task), do: %{title: task, objective: task}
  defp normalize_task(task) when is_map(task), do: task

  defp insert!({:ok, value}), do: value
  defp insert!({:error, reason}), do: Repo.rollback(reason)

  defp record_event!(objective_id, kind, payload) do
    insert!(Objectives.create_event(%{objective_id: objective_id, kind: kind, payload: payload}))
  end

  defp acknowledge_receipt(digest_field, receipt_digest, state_field, from, to, context) do
    case Repo.transaction(fn ->
           do_acknowledge_receipt(
             digest_field,
             receipt_digest,
             state_field,
             from,
             to,
             context
           )
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_acknowledge_receipt(digest_field, receipt_digest, state_field, from, to, context) do
    user_id = context_field(context, :user_id)

    query =
      Objective
      |> where([o], field(o, ^digest_field) == ^receipt_digest)
      |> where([o], field(o, ^state_field) == ^from)
      |> where([o], o.user_id == ^user_id)
      |> identity_filter(
        :source_channel,
        context_field(context, :source_channel) || context_field(context, :channel)
      )
      |> identity_filter(
        :source_thread_id,
        context_field(context, :source_thread_id) || context_field(context, :thread_id)
      )
      |> identity_filter(:origin_thread_ref_id, context_field(context, :origin_thread_ref_id))
      |> identity_filter(
        :origin_thread_ref_digest,
        context_field(context, :origin_thread_ref_digest)
      )

    objective = Repo.one(query)

    if objective && identity_matches?(objective, context) do
      transition_receipt(query, objective, state_field, to, digest_field, receipt_digest, context)
    else
      idempotent_or_denied(digest_field, receipt_digest, state_field, to, context)
    end
  end

  defp transition_receipt(
         query,
         objective,
         state_field,
         to,
         digest_field,
         receipt_digest,
         context
       ) do
    case Repo.update_all(query, set: [{state_field, to}, {:updated_at, DateTime.utc_now()}]) do
      {1, _} ->
        kind =
          case {state_field, to} do
            {:kickoff_delivery_state, "acknowledged"} -> "fanout_acknowledged"
            {:kickoff_delivery_state, "blocked"} -> "fanout_delivery_blocked"
            _other -> "report_delivered"
          end

        record_event!(objective.id, kind, %{state: to})
        :ok

      {0, _} ->
        idempotent_or_denied(digest_field, receipt_digest, state_field, to, context)
    end
  end

  defp idempotent_or_denied(digest_field, receipt_digest, state_field, expected, context) do
    case Repo.one(from o in Objective, where: field(o, ^digest_field) == ^receipt_digest) do
      %Objective{} = objective ->
        if Map.get(objective, state_field) == expected and identity_matches?(objective, context),
          do: :ok,
          else: {:error, :receipt_identity_mismatch}

      nil ->
        {:error, :invalid_receipt}
    end
  end

  defp identity_filter(query, _field, nil), do: query

  defp identity_filter(query, field_name, value),
    do: where(query, [o], field(o, ^field_name) == ^value)

  defp identity_matches?(objective, context) do
    objective.user_id == context_field(context, :user_id) and
      required_if_stored?(
        objective.source_channel,
        context_field(context, :source_channel) || context_field(context, :channel)
      ) and
      required_if_stored?(
        objective.source_thread_id,
        context_field(context, :source_thread_id) || context_field(context, :thread_id)
      ) and
      required_if_stored?(
        objective.origin_thread_ref_id,
        context_field(context, :origin_thread_ref_id)
      ) and
      required_if_stored?(
        objective.origin_thread_ref_digest,
        context_field(context, :origin_thread_ref_digest)
      ) and
      required_if_stored?(
        objective.origin_receiver_account_ref,
        context_field(context, :origin_receiver_account_ref) ||
          context_field(context, :receiver_account_ref)
      )
  end

  defp required_if_stored?(nil, _supplied), do: true
  defp required_if_stored?(stored, supplied), do: stored == supplied

  defp receipt_delivery_context(parent) do
    %{
      origin_thread_ref_id: parent.origin_thread_ref_id,
      origin_thread_ref_digest: parent.origin_thread_ref_digest,
      origin_receiver_account_ref: parent.origin_receiver_account_ref
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp context_field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  @doc false
  def receipt_for(kind, parent_id) when kind in [:start, :report] and is_binary(parent_id) do
    :crypto.mac(:hmac, :sha256, ReceiptSecret.ensure!(), "#{kind}:#{parent_id}")
    |> Base.url_encode64(padding: false)
  end

  defp digest(receipt), do: Base.encode16(:crypto.hash(:sha256, receipt), case: :lower)
end
