defmodule AllbertAssist.Objectives.Fanout do
  @moduledoc """
  Durable fan-out framing and honest terminal reduction.

  Framing is one database transaction. Receipt digests, not bearer receipts,
  are persisted; starting execution is deliberately outside this module.
  """

  import Ecto.Query

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Event
  alias AllbertAssist.Objectives.Fanout.ReceiptSecret
  alias AllbertAssist.Objectives.Fanout.TerminalTransitions
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime.Redactor

  @terminal ~w[completed cancelled failed abandoned]
  @active_kickoff_delivery_states ~w[pending blocked acknowledged]
  @report_detail_limit 500

  @spec frame(map(), [map() | String.t()]) :: {:ok, map()} | {:error, term()}
  def frame(parent_attrs, tasks) when is_map(parent_attrs) and is_list(tasks) do
    with :ok <- validate_tasks(tasks) do
      transact_frame(fn -> frame_transaction!(parent_attrs, tasks) end)
    end
  end

  @doc """
  Frame one fan-out only when its durable user/thread scope has no active parent.

  The scoped admission check and framing share one immediate transaction. Under
  Allbert's single-writer SQLite topology, concurrent callers therefore observe
  the first committed parent and cannot both frame work for the same thread.
  Awaiting kickoff, running, and recovering parents all remain admission-active
  until their report leaves `not_ready`.
  """
  @spec frame_if_inactive(map(), [map() | String.t()]) ::
          {:ok, map()} | {:error, {:fanout_already_active, Objective.t()} | term()}
  def frame_if_inactive(parent_attrs, tasks)
      when is_map(parent_attrs) and is_list(tasks) do
    with :ok <- validate_tasks(tasks),
         {:ok, {user_id, source_thread_id}} <- admission_scope(parent_attrs) do
      transact_frame(fn ->
        frame_after_admission!(user_id, source_thread_id, parent_attrs, tasks)
      end)
    end
  end

  @doc """
  Return the durable parent currently blocking fan-out admission for a scope.

  This is a direct user/thread query, not a scan of the bounded general-purpose
  objective listing. It includes awaiting-kickoff, running, and recovering
  parents and excludes parents whose joined report is pending or delivered.
  """
  @spec active_parent(String.t(), String.t()) ::
          {:ok, Objective.t()} | {:error, :not_found}
  def active_parent(user_id, source_thread_id)
      when is_binary(user_id) and is_binary(source_thread_id) do
    case active_parent_query(user_id, source_thread_id) |> Repo.one() do
      %Objective{} = parent -> {:ok, parent}
      nil -> {:error, :not_found}
    end
  end

  defp frame_after_admission!(user_id, source_thread_id, parent_attrs, tasks) do
    case active_parent_query(user_id, source_thread_id) |> Repo.one() do
      nil -> frame_transaction!(parent_attrs, tasks)
      %Objective{} = parent -> Repo.rollback({:fanout_already_active, parent})
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
        o.report_delivery_state == "not_ready"
    )
    |> order_by([o], asc: o.inserted_at, asc: o.id)
    |> Repo.all()
  end

  @doc "True when an acknowledged parent still requires durable reconciliation."
  @spec recovery_required?(Objective.t() | String.t()) :: boolean()
  def recovery_required?(%Objective{} = parent) do
    parent.fanout_role == "parent" and parent.kickoff_delivery_state == "acknowledged" and
      parent.report_delivery_state == "not_ready"
  end

  def recovery_required?(parent_id) when is_binary(parent_id) do
    case Repo.get(Objective, parent_id) do
      %Objective{} = parent -> recovery_required?(parent)
      nil -> false
    end
  end

  @doc "Return pending join reports without consuming their delivery receipts."
  @spec pending_reports(String.t(), String.t(), map()) :: [map()]
  def pending_reports(user_id, thread_id, delivery_identity)
      when is_binary(user_id) and is_binary(thread_id) and is_map(delivery_identity) do
    Objective
    |> where(
      [o],
      o.fanout_role == "parent" and o.user_id == ^user_id and
        o.source_thread_id == ^thread_id and o.report_delivery_state == "pending"
    )
    |> order_by([o], asc: o.completed_at, asc: o.id)
    |> Repo.all()
    |> Enum.filter(&delivery_identity_matches?(&1, delivery_identity))
    |> Enum.flat_map(fn parent ->
      projection = parent_projection(parent)

      if projection.phase == :joined and projection.authoritatively_joined? do
        [
          %{
            parent_objective_id: parent.id,
            report: report(projection),
            report_delivery_receipt: receipt_for(:report, parent.id),
            delivery_context: receipt_delivery_context(projection.parent)
          }
        ]
      else
        []
      end
    end)
  end

  defp delivery_identity_matches?(parent, context) do
    ref = map_field(context, :channel_thread_ref)

    presented = %{
      channel: context |> map_field(:channel) |> Objectives.normalize_channel(),
      origin_thread_ref_id: map_field(context, :origin_thread_ref_id) || map_field(ref, :id),
      origin_thread_ref_digest: map_field(context, :origin_thread_ref_digest),
      origin_receiver_account_ref:
        map_field(context, :origin_receiver_account_ref) ||
          map_field(context, :receiver_account_ref) || map_field(ref, :receiver_account_ref)
    }

    parent.source_channel == presented.channel and
      optional_identity_matches?(
        parent.origin_receiver_account_ref,
        presented.origin_receiver_account_ref
      )
  end

  defp optional_identity_matches?(nil, _presented), do: true
  defp optional_identity_matches?(stored, presented), do: stored == presented

  defp map_field(nil, _key), do: nil
  defp map_field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_field(_value, _key), do: nil

  @spec join_status(Objective.t() | String.t()) :: %{
          terminal?: boolean(),
          status: String.t(),
          outcome: String.t() | nil
        }
  def join_status(parent) do
    projection = parent_projection(parent)

    %{
      terminal?: projection.children_terminal?,
      status: projection.derived_status,
      outcome: projection.derived_join_outcome
    }
  end

  @type parent_projection :: %{
          parent: Objective.t() | nil,
          children: [Objective.t()],
          phase: :awaiting_kickoff | :running | :recovering | :joined | :inconsistent,
          display_status: String.t(),
          persisted_status: String.t() | nil,
          derived_status: String.t(),
          persisted_join_outcome: String.t() | nil,
          derived_join_outcome: String.t() | nil,
          children_terminal?: boolean(),
          authoritatively_joined?: boolean(),
          recovery_required?: boolean()
        }

  @doc "Project one fan-out parent and one ordered child snapshot for operator reads."
  @spec parent_projection(Objective.t() | String.t()) :: parent_projection()
  def parent_projection(%Objective{id: id}), do: parent_projection(id)

  def parent_projection(parent_id) when is_binary(parent_id) do
    parent = Repo.get(Objective, parent_id)
    children = children(parent_id)
    {derived_status, derived_outcome} = reduce(children)
    children_terminal? = children != [] and Enum.all?(children, &(&1.status in @terminal))
    authoritatively_joined? = authoritatively_joined?(parent_id, parent)
    recovery_required? = recovery_required_parent?(parent)

    state = %{
      parent: parent,
      children: children,
      children_terminal?: children_terminal?,
      authoritatively_joined?: authoritatively_joined?,
      reduction_matches?:
        reduction_matches?(parent, children_terminal?, derived_status, derived_outcome),
      recovery_required?: recovery_required?
    }

    phase = projection_phase(state)

    %{
      parent: parent,
      children: children,
      phase: phase,
      display_status: projection_display_status(phase, parent),
      persisted_status: parent && parent.status,
      derived_status: derived_status,
      persisted_join_outcome: parent && parent.join_outcome,
      derived_join_outcome: derived_outcome,
      children_terminal?: children_terminal?,
      authoritatively_joined?: authoritatively_joined?,
      recovery_required?: recovery_required?
    }
  end

  defp authoritatively_joined?(parent_id, parent) do
    joined_marker? = joined_marker?(parent)
    receipt_matches? = report_receipt_matches?(parent_id, parent)
    join_event? = join_event_recorded?(parent_id)

    joined_marker? and receipt_matches? and join_event?
  end

  defp joined_marker?(%Objective{fanout_role: "parent", report_delivery_state: state})
       when state in ["pending", "delivered"],
       do: true

  defp joined_marker?(_parent), do: false

  defp report_receipt_matches?(parent_id, %Objective{report_delivery_receipt_digest: digest})
       when is_binary(digest),
       do: digest == digest(receipt_for(:report, parent_id))

  defp report_receipt_matches?(_parent_id, _parent), do: false

  defp join_event_recorded?(parent_id) do
    Repo.exists?(
      from event in Event,
        where: event.objective_id == ^parent_id and event.kind == "fanout_joined"
    )
  end

  defp reduction_matches?(parent, children_terminal?, derived_status, derived_outcome) do
    children_terminal? and match?(%Objective{}, parent) and parent.status == derived_status and
      parent.join_outcome == derived_outcome
  end

  defp recovery_required_parent?(%Objective{
         fanout_role: "parent",
         kickoff_delivery_state: "acknowledged",
         report_delivery_state: "not_ready"
       }),
       do: true

  defp recovery_required_parent?(_parent), do: false

  defp projection_phase(%{
         parent: %Objective{fanout_role: "parent"},
         children: [_child | _rest],
         authoritatively_joined?: true,
         reduction_matches?: true
       }),
       do: :joined

  defp projection_phase(%{
         parent: %Objective{fanout_role: "parent"},
         children: [_child | _rest],
         authoritatively_joined?: true
       }),
       do: :inconsistent

  defp projection_phase(%{
         parent: %Objective{fanout_role: "parent"},
         children: [_child | _rest],
         recovery_required?: true,
         children_terminal?: true
       }),
       do: :recovering

  defp projection_phase(%{
         parent: %Objective{fanout_role: "parent"},
         children: [_child | _rest],
         recovery_required?: true
       }),
       do: :running

  defp projection_phase(%{
         parent: %Objective{
           fanout_role: "parent",
           kickoff_delivery_state: state,
           report_delivery_state: "not_ready"
         },
         children: [_child | _rest]
       })
       when state in ["pending", "blocked"],
       do: :awaiting_kickoff

  defp projection_phase(_state), do: :inconsistent

  @type report :: %{
          parent_objective_id: String.t(),
          status: String.t(),
          join_outcome: String.t() | nil,
          children: [map()]
        }

  @spec report(Objective.t() | String.t() | parent_projection()) :: report()
  def report(%Objective{id: id}), do: report(id)

  def report(%{parent: _parent, children: _children} = projection),
    do: report_from_projection(projection)

  def report(parent_id) when is_binary(parent_id) do
    parent_id
    |> parent_projection()
    |> report_from_projection()
  end

  defp report_from_projection(projection) do
    Redactor.redact(%{
      parent_objective_id: projection.parent && projection.parent.id,
      title: (projection.parent && projection.parent.title) || "Fan-out",
      status: projection.derived_status,
      join_outcome: projection.derived_join_outcome,
      children:
        Enum.map(projection.children, fn child ->
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

  @doc "Returns one bounded, redacted, truthful child result or terminal reason."
  @spec report_child_detail(map()) :: String.t()
  def report_child_detail(child) when is_map(child) do
    status = Map.get(child, :status) || Map.get(child, "status")
    result = Map.get(child, :result_summary) || Map.get(child, "result_summary")
    reason = Map.get(child, :review_reason) || Map.get(child, "review_reason")

    value = if status == "completed", do: result, else: reason || result

    fallback =
      if status == "completed",
        do: "No result summary recorded.",
        else: "No terminal reason recorded."

    case value |> Redactor.redact() |> to_string() |> String.trim() do
      "" -> fallback
      detail -> String.slice(detail, 0, @report_detail_limit)
    end
  end

  @doc false
  @spec format_report(report()) :: String.t()
  def format_report(report) when is_map(report) do
    children =
      Enum.map_join(report.children, "; ", fn child ->
        "#{report_glyph(child.status)} #{child.title} — #{report_child_detail(child)}"
      end)

    "#{report.title} — #{report.join_outcome || report.status}: #{children}"
  end

  defp projection_display_status(:recovering, _parent), do: "finalizing"
  defp projection_display_status(:running, _parent), do: "running"
  defp projection_display_status(:inconsistent, _parent), do: "inconsistent"
  defp projection_display_status(_phase, %Objective{status: status}), do: status
  defp projection_display_status(_phase, nil), do: "inconsistent"

  defp report_glyph("completed"), do: "✓"
  defp report_glyph("cancelled"), do: "⊘"
  defp report_glyph("failed"), do: "✗"
  defp report_glyph(_status), do: "•"

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

  @doc false
  @spec parent_for_start_receipt(String.t(), map()) ::
          {:ok, Objective.t()} | {:error, :invalid_receipt | :receipt_identity_mismatch}
  def parent_for_start_receipt(receipt, context)
      when is_binary(receipt) and is_map(context) do
    receipt_digest = digest(receipt)

    case Repo.one(
           from objective in Objective,
             where:
               objective.fanout_role == "parent" and
                 objective.fanout_start_receipt_digest == ^receipt_digest
         ) do
      %Objective{} = parent ->
        if identity_matches?(parent, context),
          do: {:ok, parent},
          else: {:error, :receipt_identity_mismatch}

      nil ->
        {:error, :invalid_receipt}
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

  @doc "Idempotently reconcile a parent from durable child state."
  @spec reconcile_parent(Objective.t() | String.t(), keyword()) ::
          {:ok, TerminalTransitions.join_result()} | {:error, term()}
  def reconcile_parent(parent, opts \\ [])
  def reconcile_parent(%Objective{id: id}, opts), do: reconcile_parent(id, opts)

  def reconcile_parent(parent_id, opts) when is_binary(parent_id) and is_list(opts),
    do: TerminalTransitions.reconcile_parent(parent_id, opts)

  @doc "Persists or reads a terminal join and returns its stable report receipt."
  @spec finalize_join(Objective.t() | String.t()) :: {:ok, map()} | {:error, term()}
  def finalize_join(%Objective{id: id}), do: finalize_join(id)

  def finalize_join(parent_id) when is_binary(parent_id) do
    case reconcile_parent(parent_id, recovered?: false) do
      {:ok, {state, parent}} when state in [:joined_now, :already_joined] ->
        {:ok,
         %{
           parent: parent,
           report: report(parent),
           report_delivery_receipt: receipt_for(:report, parent_id)
         }}

      {:ok, :not_terminal} ->
        {:error, :fanout_not_terminal_or_already_finalized}

      {:error, reason} ->
        {:error, reason}
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

    proposed_payload =
      %{child_ids: Enum.map(children, & &1.id), child_count: length(children)}
      |> Map.merge(plan_provenance(attrs))

    insert!(
      Objectives.create_event(%{
        objective_id: parent.id,
        kind: "fanout_proposed",
        payload: proposed_payload
      })
    )

    %{parent: parent, children: children, fanout_start_receipt: receipt}
  end

  defp active_parent_query(user_id, source_thread_id) do
    Objective
    |> where(
      [objective],
      objective.fanout_role == "parent" and objective.user_id == ^user_id and
        objective.source_thread_id == ^source_thread_id and
        objective.report_delivery_state == "not_ready" and
        objective.kickoff_delivery_state in ^@active_kickoff_delivery_states
    )
    |> order_by([objective], desc: objective.inserted_at, desc: objective.id)
    |> limit(1)
  end

  defp admission_scope(attrs) do
    user_id = map_field(attrs, :user_id)
    source_thread_id = map_field(attrs, :source_thread_id)

    if present_binary?(user_id) and present_binary?(source_thread_id) do
      {:ok, {user_id, source_thread_id}}
    else
      {:error, :fanout_admission_scope_required}
    end
  end

  defp present_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_binary?(_value), do: false

  defp transact_frame(fun) when is_function(fun, 0),
    do: Repo.transaction(fun, mode: :immediate)

  defp plan_provenance(attrs) do
    attrs
    |> map_field(:proposer_hint)
    |> map_field(:fanout_plan)
    |> case do
      %{} = provenance ->
        %{
          plan_version: map_field(provenance, :version),
          plan_source: map_field(provenance, :source),
          original_request_sha256: map_field(provenance, :original_request_sha256),
          plan_sha256: map_field(provenance, :plan_sha256),
          manager_profile: map_field(provenance, :manager_profile),
          manager_profile_sha256: map_field(provenance, :manager_profile_sha256),
          manager_attempts: map_field(provenance, :manager_attempts),
          budget: map_field(provenance, :budget),
          deadline_unix_ms: map_field(provenance, :deadline_unix_ms)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _other ->
        %{}
    end
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
        context_channel(context)
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
        context_channel(context)
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

  defp context_channel(context) do
    Objectives.normalize_channel(context_field(context, :source_channel)) ||
      Objectives.normalize_channel(context_field(context, :channel))
  end

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
