defmodule AllbertAssist.Objectives.Fanout do
  @moduledoc """
  Durable fan-out framing and honest terminal reduction.

  Framing is one database transaction. Receipt digests, not bearer receipts,
  are persisted; starting execution is deliberately outside this module.
  """

  import Ecto.Query

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Event
  alias AllbertAssist.Objectives.Fanout.PlanProvenance
  alias AllbertAssist.Objectives.Fanout.ReceiptSecret
  alias AllbertAssist.Objectives.Fanout.Report
  alias AllbertAssist.Objectives.Fanout.ReportComposer
  alias AllbertAssist.Objectives.Fanout.TerminalTransitions
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Objectives.Runs.Scheduler
  alias AllbertAssist.Objectives.Runs.Worker.{Grounding, QualityPolicy, QualityReceipt}
  alias AllbertAssist.Objectives.Step
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime.Redactor

  @terminal ~w[completed cancelled failed abandoned]
  @noncompleted_terminal ~w[cancelled failed abandoned]
  @compatible_noncompleted_step_statuses Step.statuses()
  @active_kickoff_delivery_states ~w[pending blocked acknowledged]
  @report_detail_limit 500
  @composition_work_batch_size 100

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

  @doc "Verify one parent's closed plan against its proposal event and child order."
  @spec verified_plan(Objective.t()) ::
          {:ok, map()} | {:error, :missing_plan_provenance | term()}
  def verified_plan(%Objective{proposer_hint: nil}), do: {:error, :missing_plan_provenance}

  def verified_plan(%Objective{} = parent) do
    proposed_events =
      Event
      |> where([event], event.objective_id == ^parent.id and event.kind == "fanout_proposed")
      |> order_by([event], asc: event.recorded_at, asc: event.id)
      |> Repo.all()

    child_ids = parent |> children() |> Enum.map(& &1.id)

    case proposed_events do
      [%Event{payload: payload}] ->
        PlanProvenance.verify_binding(parent.proposer_hint, payload, child_ids)

      _missing_or_duplicate ->
        {:error, :invalid_fanout_plan_provenance}
    end
  end

  @doc "Reconstruct and verify the canonical frozen report input from durable rows."
  @spec report_input(Objective.t() | String.t()) ::
          {:ok, Report.frozen()} | {:error, term()}
  def report_input(%Objective{} = parent) do
    report_parent = report_parent(parent)
    report_children = children(parent.id)

    case parent.report_input_digest do
      nil ->
        report_input_v2(parent, report_parent, report_children)

      digest when is_binary(digest) ->
        report_input_for_digest(parent, report_parent, report_children, digest)
    end
  end

  def report_input(parent_id) when is_binary(parent_id) do
    case Repo.get(Objective, parent_id) do
      %Objective{} = parent -> report_input(parent)
      nil -> {:error, :fanout_parent_not_found}
    end
  end

  defp report_input_for_digest(parent, report_parent, report_children, digest) do
    with {:ok, v1_frozen} <- report_input_v1(parent, report_parent, report_children) do
      resolve_report_input_version(v1_frozen, parent, report_parent, report_children, digest)
    end
  end

  defp resolve_report_input_version(
         %{input_digest: digest} = v1_frozen,
         _parent,
         _report_parent,
         _report_children,
         digest
       ),
       do: {:ok, v1_frozen}

  defp resolve_report_input_version(
         _v1_frozen,
         parent,
         report_parent,
         report_children,
         digest
       ) do
    with {:ok, v2_frozen} <- report_input_v2(parent, report_parent, report_children),
         :ok <- Report.verify(v2_frozen, digest) do
      {:ok, v2_frozen}
    end
  end

  @doc false
  @spec report_input_v1(Objective.t()) :: {:ok, Report.frozen()} | {:error, term()}
  def report_input_v1(%Objective{} = parent) do
    report_input_v1(parent, report_parent(parent), children(parent.id))
  end

  @doc false
  @spec report_input_v2(Objective.t()) :: {:ok, Report.frozen()} | {:error, term()}
  def report_input_v2(%Objective{} = parent) do
    report_input_v2(parent, report_parent(parent), children(parent.id))
  end

  @doc false
  @spec report_input_for_selection(Objective.t()) ::
          {:ok, %{frozen: Report.frozen(), rebind_from: String.t() | nil}} | {:error, term()}
  def report_input_for_selection(%Objective{} = parent) do
    with {:ok, persisted} <- report_input(parent) do
      selection_report_input(parent, persisted)
    end
  end

  defp selection_report_input(_parent, %{snapshot: %{version: 2}} = persisted),
    do: {:ok, %{frozen: persisted, rebind_from: nil}}

  defp selection_report_input(parent, %{snapshot: %{version: 1}} = persisted) do
    with {:ok, current} <- report_input_v2(parent) do
      {:ok, %{frozen: current, rebind_from: persisted.input_digest}}
    end
  end

  defp report_input_v2(_parent, report_parent, report_children) do
    with :ok <- Report.validate_structure(report_parent, report_children),
         {:ok, child_authorities} <- report_child_authorities(report_children) do
      Report.freeze_v2(
        report_parent,
        report_children,
        v2_effect_evidence_refs(report_children),
        child_authorities
      )
    end
  end

  defp report_input_v1(_parent, report_parent, report_children) do
    with :ok <- Report.validate_structure(report_parent, report_children) do
      Report.freeze(
        report_parent,
        report_children,
        effect_evidence_refs(report_parent.id)
      )
    end
  end

  defp report_parent(parent) do
    case verified_plan(parent) do
      {:ok, plan} ->
        {:ok, encoded} = PlanProvenance.encode_parent_hint(plan)
        %{parent | proposer_hint: encoded}

      {:error, :missing_plan_provenance} ->
        parent

      {:error, _invalid_or_mismatched} ->
        %{parent | proposer_hint: nil}
    end
  end

  @doc "Claim the oldest queued report composition and return its verified input."
  @spec claim_next_composition() ::
          {:ok, TerminalTransitions.composition_claim()} | :none | {:error, term()}
  def claim_next_composition, do: TerminalTransitions.claim_next_composition()

  @doc "Select one report with bounded, content-free composition provenance."
  @spec select_composition(
          TerminalTransitions.composition_claim(),
          String.t(),
          String.t(),
          map()
        ) ::
          {:ok, Objective.t()} | {:error, term()}
  def select_composition(claim, source, body, provenance),
    do: TerminalTransitions.select_composition(claim, source, body, provenance)

  @doc "Recover interrupted composition and legacy selected-report rows at boot."
  @spec recover_composition() :: {:ok, non_neg_integer()} | {:error, term()}
  def recover_composition, do: TerminalTransitions.recover_composition()

  @doc "Wake the durable owner for a parent that currently projects as recovering."
  @spec wake_recovery(Objective.t() | String.t(), keyword()) :: :ok
  def wake_recovery(parent, opts \\ [])

  def wake_recovery(
        %Objective{
          report_composition_state: "queued",
          id: parent_id
        },
        opts
      ) do
    ReportComposer.enqueue(parent_id, Keyword.get(opts, :composer, ReportComposer))
  end

  def wake_recovery(
        %Objective{
          report_composition_state: composition_state,
          report_delivery_state: delivery_state,
          id: parent_id
        },
        opts
      )
      when composition_state == "composing" or
             (composition_state == "not_ready" and delivery_state in ["pending", "delivered"]) do
    ReportComposer.reconcile(parent_id, Keyword.get(opts, :composer, ReportComposer))
  end

  def wake_recovery(%Objective{id: parent_id}, opts) do
    Scheduler.wake_parent(parent_id, Keyword.get(opts, :scheduler, Scheduler))
  end

  def wake_recovery(parent_id, opts) when is_binary(parent_id) do
    case Repo.get(Objective, parent_id) do
      %Objective{} = parent -> wake_recovery(parent, opts)
      nil -> :ok
    end
  end

  @doc false
  @spec composition_work_batch(nil | {DateTime.t() | nil, String.t()}) ::
          {:done, [Objective.t()]} | {:more, [Objective.t()], {DateTime.t() | nil, String.t()}}
  def composition_work_batch(cursor \\ nil) do
    work =
      Objective
      |> where(
        [objective],
        objective.fanout_role == "parent" and
          (objective.report_composition_state in ["queued", "composing"] or
             (objective.report_composition_state == "not_ready" and
                objective.report_delivery_state in ["pending", "delivered"]))
      )
      |> after_composition_work_cursor(cursor)
      |> order_by([objective], asc: objective.completed_at, asc: objective.id)
      |> limit(@composition_work_batch_size)
      |> Repo.all()

    if length(work) < @composition_work_batch_size do
      {:done, work}
    else
      last = List.last(work)
      {:more, work, {last.completed_at, last.id}}
    end
  end

  defp after_composition_work_cursor(query, nil), do: query

  defp after_composition_work_cursor(query, {nil, id}) do
    where(
      query,
      [objective],
      (is_nil(objective.completed_at) and objective.id > ^id) or
        not is_nil(objective.completed_at)
    )
  end

  defp after_composition_work_cursor(query, {completed_at, id}) do
    where(
      query,
      [objective],
      objective.completed_at > ^completed_at or
        (objective.completed_at == ^completed_at and objective.id > ^id)
    )
  end

  @doc "Return acknowledged fan-out parents eligible for executor reconciliation."
  @spec runnable_parents() :: [Objective.t()]
  def runnable_parents do
    Objective
    |> where(
      [o],
      o.fanout_role == "parent" and o.kickoff_delivery_state == "acknowledged" and
        o.report_delivery_state == "not_ready" and o.report_composition_state == "not_ready"
    )
    |> order_by([o], asc: o.inserted_at, asc: o.id)
    |> Repo.all()
  end

  @doc "True when an acknowledged parent still requires durable reconciliation."
  @spec recovery_required?(Objective.t() | String.t()) :: boolean()
  def recovery_required?(%Objective{} = parent) do
    parent.fanout_role == "parent" and parent.kickoff_delivery_state == "acknowledged" and
      parent.report_delivery_state == "not_ready" and
      parent.report_composition_state == "not_ready"
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
        o.source_thread_id == ^thread_id and o.report_delivery_state == "pending" and
        o.report_composition_state in ["ready", "fallback"]
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
          composition_input_valid?: boolean(),
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
    composition_input_valid? = composition_input_valid?(parent, children)
    recovery_required? = recovery_required_parent?(parent)

    state = %{
      parent: parent,
      children: children,
      children_terminal?: children_terminal?,
      authoritatively_joined?: authoritatively_joined?,
      composition_input_valid?: composition_input_valid?,
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
      composition_input_valid?: composition_input_valid?,
      recovery_required?: recovery_required?
    }
  end

  defp authoritatively_joined?(parent_id, parent) do
    joined_marker? = joined_marker?(parent)
    receipt_matches? = report_receipt_matches?(parent_id, parent)
    selection_payload = report_selection_payload(parent_id)
    selection_integrity? = selected_report_integrity?(parent, selection_payload)
    selection_event_matches? = report_selection_matches?(selection_payload, parent)
    join_event_matches? = join_event_matches?(parent_id, parent, selection_payload)

    joined_marker? and receipt_matches? and selection_event_matches? and join_event_matches? and
      selection_integrity?
  end

  defp joined_marker?(%Objective{
         fanout_role: "parent",
         report_composition_state: "ready",
         report_delivery_state: delivery_state,
         report_body: body,
         report_source: "model",
         report_input_digest: digest,
         report_selection_digest: selection_digest
       })
       when delivery_state in ["pending", "delivered"] and is_binary(body) and
              is_binary(digest) and is_binary(selection_digest),
       do: true

  defp joined_marker?(%Objective{
         fanout_role: "parent",
         report_composition_state: "fallback",
         report_delivery_state: delivery_state,
         report_body: body,
         report_source: "deterministic_fallback",
         report_input_digest: digest,
         report_selection_digest: selection_digest
       })
       when delivery_state in ["pending", "delivered"] and is_binary(body) and
              is_binary(digest) and is_binary(selection_digest),
       do: true

  defp joined_marker?(_parent), do: false

  defp report_receipt_matches?(parent_id, %Objective{report_delivery_receipt_digest: digest})
       when is_binary(digest),
       do: digest == digest(receipt_for(:report, parent_id))

  defp report_receipt_matches?(_parent_id, _parent), do: false

  defp join_event_matches?(parent_id, %Objective{} = parent, selection_payload) do
    case event_payload(parent_id, "fanout_joined") do
      %{} = payload ->
        join_payload_matches?(payload, parent, selection_payload)

      nil ->
        false
    end
  end

  defp join_event_matches?(_parent_id, _parent, _selection_payload), do: false

  defp join_payload_matches?(payload, parent, selection_payload) do
    join_base_matches?(payload, parent) and
      (current_join_input_matches?(payload, parent) or
         upgraded_v1_join_matches?(payload, parent, selection_payload) or
         legacy_backfill_join_matches?(payload, selection_payload))
  end

  defp join_base_matches?(payload, parent),
    do:
      payload["status"] == parent.status and
        payload["join_outcome"] == parent.join_outcome

  defp current_join_input_matches?(payload, parent),
    do:
      payload["report_composition_state"] == "queued" and
        payload["report_input_digest"] == parent.report_input_digest

  defp upgraded_v1_join_matches?(payload, parent, selection_payload),
    do:
      payload["report_composition_state"] == "queued" and
        selection_payload["layout_version"] == 2 and
        selection_payload["input_digest"] == parent.report_input_digest and
        v1_join_input_matches?(parent, payload["report_input_digest"])

  defp legacy_backfill_join_matches?(payload, selection_payload),
    do:
      is_nil(payload["report_composition_state"]) and
        is_nil(payload["report_input_digest"]) and
        selection_payload["historical_backfill"] == true

  defp v1_join_input_matches?(%Objective{} = parent, event_digest)
       when is_binary(event_digest) do
    report_parent = report_parent(parent)
    report_children = children(parent.id)

    case Report.freeze(
           report_parent,
           report_children,
           effect_evidence_refs(parent.id)
         ) do
      {:ok, frozen} -> frozen.input_digest == event_digest
      {:error, _reason} -> false
    end
  end

  defp v1_join_input_matches?(_parent, _event_digest), do: false

  defp report_selection_payload(parent_id),
    do: event_payload(parent_id, "fanout_report_selected") || %{}

  defp report_selection_matches?(payload, %Objective{} = parent) do
    provenance = selection_provenance(parent.report_source, payload)

    payload["source"] == parent.report_source and
      payload["input_digest"] == parent.report_input_digest and
      payload["body_sha256"] == digest(parent.report_body || "") and
      report_selection_provenance_matches?(payload, parent.report_source) and
      selection_digest_matches?(parent, provenance)
  end

  defp report_selection_matches?(_payload, _parent), do: false

  defp report_selection_provenance_matches?(payload, "model") do
    provenance_keys =
      if payload["layout_version"] == 2 do
        ~w[
          layout_version model model_profile provider review_verdict reviewed_queue_positions
          sections synthesis_contract_version synthesis_sha256
        ]
      else
        ~w[layout_version model model_profile provider sections]
      end

    expected_keys = Enum.sort(~w[body_sha256 input_digest source] ++ provenance_keys)

    payload_keys(payload) == expected_keys and
      match?(
        {:ok, _normalized},
        Report.normalize_selection_provenance(
          "model",
          Map.take(payload, provenance_keys)
        )
      )
  end

  defp report_selection_provenance_matches?(payload, "deterministic_fallback") do
    reason = payload["fallback_reason"]
    historical? = reason == "historical_backfill"
    v2? = payload["layout_version"] == 2

    provenance_keys =
      if v2?,
        do: ~w[
            fallback_reason layout_version synthesis_contract_version synthesis_outcome
          ],
        else: ~w[fallback_reason layout_version]

    expected_keys =
      if historical?,
        do: Enum.sort(~w[body_sha256 historical_backfill input_digest source] ++ provenance_keys),
        else: Enum.sort(~w[body_sha256 input_digest source] ++ provenance_keys)

    payload_keys(payload) == expected_keys and
      payload["historical_backfill"] == if(historical?, do: true, else: nil) and
      match?(
        {:ok, _normalized},
        Report.normalize_selection_provenance(
          "deterministic_fallback",
          Map.take(payload, provenance_keys)
        )
      )
  end

  defp report_selection_provenance_matches?(_payload, _source), do: false

  defp selection_digest_matches?(
         %Objective{report_source: source, report_selection_digest: stored},
         provenance
       )
       when is_binary(source) and is_binary(stored) and is_map(provenance) do
    case Report.selection_digest(source, provenance) do
      {:ok, computed} -> computed == stored
      {:error, _reason} -> false
    end
  end

  defp selection_digest_matches?(_parent, _provenance), do: false

  defp payload_keys(payload), do: payload |> Map.keys() |> Enum.sort()

  defp event_payload(parent_id, kind) do
    case Repo.one(
           from event in Event,
             where: event.objective_id == ^parent_id and event.kind == ^kind,
             select: event.payload,
             limit: 1
         ) do
      payload when is_binary(payload) ->
        case Jason.decode(payload) do
          {:ok, %{} = decoded} -> decoded
          _invalid -> nil
        end

      _missing ->
        nil
    end
  end

  defp selected_report_integrity?(
         %Objective{
           report_source: source,
           report_body: body
         } = parent,
         selection_payload
       )
       when is_binary(source) and is_binary(body) and is_map(selection_payload) do
    provenance = selection_provenance(source, selection_payload)

    with {:ok, frozen} <- report_input(parent),
         :ok <- Report.validate_selected_body(frozen.snapshot, source, body, provenance) do
      true
    else
      _error -> false
    end
  end

  defp selected_report_integrity?(_parent, _selection_payload), do: false

  defp selection_provenance("model", %{"layout_version" => 2} = payload),
    do:
      Map.take(
        payload,
        ~w[
          layout_version model model_profile provider review_verdict reviewed_queue_positions
          sections synthesis_contract_version synthesis_sha256
        ]
      )

  defp selection_provenance("model", payload),
    do: Map.take(payload, ~w[layout_version model model_profile provider sections])

  defp selection_provenance(
         "deterministic_fallback",
         %{"layout_version" => 2} = payload
       ),
       do:
         Map.take(
           payload,
           ~w[fallback_reason layout_version synthesis_contract_version synthesis_outcome]
         )

  defp selection_provenance("deterministic_fallback", payload),
    do: Map.take(payload, ~w[fallback_reason layout_version])

  defp selection_provenance(_source, _payload), do: %{}

  defp composition_input_valid?(
         %Objective{report_composition_state: state} = parent,
         _children
       )
       when state in ["queued", "composing", "ready", "fallback"] do
    match?({:ok, _frozen}, report_input(parent))
  end

  defp composition_input_valid?(_parent, _children), do: true

  defp reduction_matches?(parent, children_terminal?, derived_status, derived_outcome) do
    children_terminal? and match?(%Objective{}, parent) and parent.status == derived_status and
      parent.join_outcome == derived_outcome
  end

  defp recovery_required_parent?(%Objective{
         fanout_role: "parent",
         kickoff_delivery_state: "acknowledged",
         report_delivery_state: "not_ready",
         report_composition_state: "not_ready"
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
         parent: %Objective{fanout_role: "parent", report_composition_state: state},
         children: [_child | _rest],
         children_terminal?: true,
         reduction_matches?: true,
         composition_input_valid?: true
       })
       when state in ["queued", "composing"],
       do: :recovering

  defp projection_phase(%{
         parent: %Objective{fanout_role: "parent", report_composition_state: state},
         children: [_child | _rest],
         composition_input_valid?: false
       })
       when state in ["queued", "composing", "ready", "fallback"],
       do: :inconsistent

  defp projection_phase(%{
         parent: %Objective{
           fanout_role: "parent",
           report_composition_state: "not_ready",
           report_delivery_state: state
         },
         children: [_child | _rest],
         children_terminal?: true,
         reduction_matches?: true
       })
       when state in ["pending", "delivered"],
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
          children: [map()],
          body: String.t() | nil,
          source: String.t() | nil,
          input_digest: String.t() | nil
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
    metadata =
      Redactor.redact(%{
        parent_objective_id: projection.parent && projection.parent.id,
        title: (projection.parent && projection.parent.title) || "Fan-out",
        status: projection.derived_status,
        join_outcome: projection.derived_join_outcome,
        source: projection.parent && projection.parent.report_source,
        input_digest: projection.parent && projection.parent.report_input_digest,
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

    Map.put(metadata, :body, authoritative_report_body(projection))
  end

  defp authoritative_report_body(%{
         authoritatively_joined?: true,
         parent: %Objective{report_body: body}
       })
       when is_binary(body),
       do: body

  defp authoritative_report_body(_projection), do: nil

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
  def format_report(%{body: body}) when is_binary(body), do: body
  def format_report(_report), do: ""

  defp projection_display_status(:recovering, _parent), do: "finalizing"
  defp projection_display_status(:running, _parent), do: "running"
  defp projection_display_status(:inconsistent, _parent), do: "inconsistent"
  defp projection_display_status(_phase, %Objective{status: status}), do: status
  defp projection_display_status(_phase, nil), do: "inconsistent"

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
      {:ok, {state, %Objective{report_composition_state: composition_state} = parent}}
      when state in [:joined_now, :already_joined] and composition_state in ["ready", "fallback"] ->
        {:ok,
         %{
           parent: parent,
           report: report(parent),
           report_delivery_receipt: receipt_for(:report, parent_id)
         }}

      {:ok, {state, %Objective{report_composition_state: composition_state}}}
      when state in [:joined_now, :already_joined] and
             composition_state in ["queued", "composing"] ->
        {:error, :fanout_report_composition_pending}

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
    {attrs, plan} = prepare_plan_provenance!(attrs)
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

    child_ids = Enum.map(children, & &1.id)

    proposed_payload =
      case plan do
        %{} = provenance ->
          case PlanProvenance.encode_proposal_event(provenance, child_ids) do
            {:ok, encoded} -> encoded
            {:error, reason} -> Repo.rollback(reason)
          end

        nil ->
          %{child_ids: child_ids, child_count: length(children)}
      end

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

  defp prepare_plan_provenance!(attrs) do
    hint = map_field(attrs, :proposer_hint)

    if fanout_plan_hint?(hint) do
      with {:ok, plan} <- PlanProvenance.decode_parent_hint(hint),
           {:ok, encoded} <- PlanProvenance.encode_parent_hint(plan) do
        {attrs |> Map.delete("proposer_hint") |> Map.put(:proposer_hint, encoded), plan}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      {attrs, nil}
    end
  end

  defp fanout_plan_hint?(%{} = hint), do: is_map(map_field(hint, :fanout_plan))

  defp fanout_plan_hint?(hint) when is_binary(hint) do
    case Jason.decode(hint) do
      {:ok, %{} = decoded} -> fanout_plan_hint?(decoded)
      _invalid -> false
    end
  end

  defp fanout_plan_hint?(_hint), do: false

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

  defp report_child_authorities(children) do
    child_ids = Enum.map(children, & &1.id)
    run_completed_events = run_completed_events_by_child(child_ids)
    steps = terminal_steps_by_id(children, run_completed_events)

    children
    |> Enum.reduce_while({:ok, %{}}, fn child, {:ok, authorities} ->
      step = Map.get(steps, child.current_step_id)
      events = Map.get(run_completed_events, child.id, [])

      case child_report_authority(child, step, events, steps) do
        {:ok, authority} ->
          {:cont, {:ok, Map.put(authorities, child.id, authority)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp child_report_authority(
         %Objective{status: "completed", current_step_id: nil} = child,
         nil,
         events,
         steps
       ),
       do: legacy_nil_pointer_authority(child, events, steps)

  defp child_report_authority(child, step, events, _steps),
    do: child_report_authority(child, step, events)

  defp child_report_authority(
         %Objective{id: child_id},
         %Step{objective_id: step_child_id},
         _events
       )
       when child_id != step_child_id,
       do: {:error, :invalid_fanout_report_terminal_step}

  defp child_report_authority(%Objective{status: "completed"} = child, step, events) do
    with :ok <- validate_child_step_status(child, step) do
      case step && step.candidate_action do
        "direct_answer" -> reviewed_or_legacy_authority(child, step, events)
        nil -> reviewed_or_legacy_authority(child, step, events)
        _registered_action -> registered_action_authority(child, step, events)
      end
    end
  end

  defp child_report_authority(%Objective{} = child, step, events) do
    with :ok <- validate_child_step_status(child, step) do
      case step && step.candidate_action do
        action when is_binary(action) and action != "direct_answer" ->
          registered_action_authority(child, step, events)

        _direct_or_historical ->
          noncompleted_legacy_authority(events)
      end
    end
  end

  defp noncompleted_legacy_authority(events) do
    with :ok <- ensure_no_completion_event(events) do
      {:ok,
       %{
         result_authority: "legacy_unreviewed_advisory",
         quality_receipt_sha256: nil
       }}
    end
  end

  defp validate_child_step_status(%Objective{current_step_id: nil}, nil), do: :ok

  defp validate_child_step_status(%Objective{}, nil),
    do: {:error, :invalid_fanout_report_terminal_step}

  defp validate_child_step_status(%Objective{status: "completed"}, %Step{status: "completed"}),
    do: :ok

  defp validate_child_step_status(%Objective{status: status}, %Step{status: step_status})
       when status in @noncompleted_terminal and
              step_status in @compatible_noncompleted_step_statuses,
       do: :ok

  defp validate_child_step_status(_child, _step),
    do: {:error, :invalid_fanout_report_terminal_step}

  defp reviewed_or_legacy_authority(child, step, [event]) do
    cond do
      quality_receipt_event?(event) ->
        reviewed_authority(child, step, event)

      legacy_completion_event?(event, child, step) ->
        {:ok,
         %{
           result_authority: "legacy_unreviewed_advisory",
           quality_receipt_sha256: nil
         }}

      true ->
        {:error, :invalid_fanout_report_quality_receipt}
    end
  end

  defp reviewed_or_legacy_authority(_child, _step, []),
    do: {:error, :missing_fanout_report_completion_event}

  defp reviewed_or_legacy_authority(_child, _step, _events),
    do: {:error, :invalid_fanout_report_quality_receipt}

  defp reviewed_authority(
         %Objective{current_step_id: step_id} = child,
         %Step{id: step_id, status: "completed", candidate_action: "direct_answer"} = step,
         event
       ) do
    with true <- step.objective_id == child.id,
         {:ok, task_contract} <- child |> Grounding.resolve() |> QualityPolicy.build(),
         {:ok, task_digests} <- QualityPolicy.receipt_task_digests(task_contract),
         final_answer when is_binary(final_answer) <-
           child.last_observation_summary || child.progress_summary,
         {:ok, _receipt, receipt_digest} <-
           QualityReceipt.from_event_payload(event.payload, %{
             objective_id: child.id,
             step_id: step.id,
             task_contract_sha256: task_digests["2"],
             task_contract_sha256_by_rule_catalog_version: task_digests,
             final_answer: final_answer
           }) do
      {:ok,
       %{
         result_authority: "reviewed_advisory",
         quality_receipt_sha256: receipt_digest
       }}
    else
      _invalid -> {:error, :invalid_fanout_report_quality_receipt}
    end
  end

  defp reviewed_authority(_child, _step, _event),
    do: {:error, :invalid_fanout_report_quality_receipt}

  defp registered_action_authority(
         %Objective{status: "completed"} = child,
         %Step{candidate_action: action, status: "completed"} = step,
         [event]
       )
       when is_binary(action) and action != "direct_answer" do
    with {:ok, _action_module} <- resolve_report_action(action),
         true <- legacy_completion_event?(event, child, step) do
      {:ok,
       %{
         result_authority: "registered_action",
         quality_receipt_sha256: nil
       }}
    else
      {:error, _reason} = error -> error
      false -> {:error, :invalid_fanout_report_completion_event}
    end
  end

  defp registered_action_authority(
         %Objective{status: "completed"},
         %Step{candidate_action: action, status: "completed"},
         events
       )
       when is_binary(action) and action != "direct_answer" do
    with {:ok, _action_module} <- resolve_report_action(action) do
      case events do
        [] -> {:error, :missing_fanout_report_completion_event}
        _unexpected -> {:error, :invalid_fanout_report_completion_event}
      end
    end
  end

  defp registered_action_authority(
         %Objective{status: child_status},
         %Step{candidate_action: action, status: step_status},
         []
       )
       when child_status in @noncompleted_terminal and
              step_status in @compatible_noncompleted_step_statuses and is_binary(action) and
              action != "direct_answer" do
    with {:ok, _action_module} <- resolve_report_action(action) do
      {:ok,
       %{
         result_authority: "registered_action",
         quality_receipt_sha256: nil
       }}
    end
  end

  defp registered_action_authority(
         %Objective{status: child_status},
         %Step{candidate_action: action, status: step_status},
         _events
       )
       when child_status in @noncompleted_terminal and
              step_status in @compatible_noncompleted_step_statuses and is_binary(action) and
              action != "direct_answer",
       do: {:error, :invalid_fanout_report_completion_event}

  defp registered_action_authority(_child, _step, _events),
    do: {:error, :invalid_fanout_report_registered_action}

  defp resolve_report_action(action) do
    case ActionsRegistry.resolve(action) do
      {:ok, action_module} -> {:ok, action_module}
      {:error, _unknown} -> {:error, :invalid_fanout_report_registered_action}
    end
  end

  defp ensure_no_completion_event([]), do: :ok

  defp ensure_no_completion_event(_events),
    do: {:error, :invalid_fanout_report_completion_event}

  defp terminal_steps_by_id(children, events_by_child) do
    current_step_ids = children |> Enum.map(& &1.current_step_id) |> Enum.reject(&is_nil/1)

    legacy_step_ids =
      Enum.flat_map(children, &legacy_child_step_ids(&1, events_by_child))

    step_ids = Enum.uniq(current_step_ids ++ legacy_step_ids)

    Step
    |> where([step], step.id in ^step_ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp legacy_child_step_ids(%Objective{current_step_id: nil, id: child_id}, events_by_child) do
    events_by_child
    |> Map.get(child_id, [])
    |> legacy_event_step_ids()
  end

  defp legacy_child_step_ids(_child, _events_by_child), do: []

  defp legacy_event_step_ids([event]) do
    case legacy_event_step_id(event) do
      {:ok, step_id} -> [step_id]
      :none -> []
    end
  end

  defp legacy_event_step_ids(_events), do: []

  defp legacy_nil_pointer_authority(child, [event], steps) do
    with {:ok, payload} <- decode_event_payload(event.payload),
         :ok <- validate_legacy_nil_pointer_payload(child, payload, steps) do
      {:ok,
       %{
         result_authority: "legacy_unreviewed_advisory",
         quality_receipt_sha256: nil
       }}
    else
      _invalid -> {:error, :invalid_fanout_report_completion_event}
    end
  end

  defp legacy_nil_pointer_authority(_child, [], _steps),
    do: {:error, :missing_fanout_report_completion_event}

  defp legacy_nil_pointer_authority(_child, _events, _steps),
    do: {:error, :invalid_fanout_report_completion_event}

  defp validate_legacy_nil_pointer_payload(child, %{"summary" => summary} = payload, _steps)
       when map_size(payload) == 1 and is_binary(summary) do
    if ordinary_result_summaries_match?(child, nil, summary),
      do: :ok,
      else: {:error, :invalid_summary}
  end

  defp validate_legacy_nil_pointer_payload(
         child,
         %{"summary" => summary, "step_id" => step_id} = payload,
         steps
       )
       when map_size(payload) == 2 and is_binary(summary) and is_binary(step_id),
       do: validate_legacy_named_step(child, Map.get(steps, step_id), summary)

  defp validate_legacy_nil_pointer_payload(
         child,
         %{
           "summary" => summary,
           "step_id" => step_id,
           "step_status" => "completed"
         } = payload,
         steps
       )
       when map_size(payload) == 3 and is_binary(summary) and is_binary(step_id),
       do: validate_legacy_named_step(child, Map.get(steps, step_id), summary)

  defp validate_legacy_nil_pointer_payload(
         child,
         %{
           "summary" => summary,
           "step_id" => step_id,
           "step_status" => "completed",
           "quality_receipt" => receipt
         } = payload,
         steps
       )
       when map_size(payload) == 4 and is_binary(summary) and is_binary(step_id) and
              is_map(receipt) do
    with %Step{} = step <- Map.get(steps, step_id),
         :ok <- validate_legacy_named_step(child, step, summary),
         :ok <- validate_legacy_receipt_binding(child, step, receipt) do
      :ok
    else
      _invalid -> {:error, :invalid_receipt_binding}
    end
  end

  defp validate_legacy_nil_pointer_payload(_child, _payload, _steps),
    do: {:error, :unknown_legacy_payload}

  defp validate_legacy_named_step(
         %Objective{id: child_id} = child,
         %Step{objective_id: child_id, status: "completed"} = step,
         summary
       ) do
    if ordinary_result_summaries_match?(child, step, summary),
      do: :ok,
      else: {:error, :invalid_summary_binding}
  end

  defp validate_legacy_named_step(_child, _step, _summary),
    do: {:error, :invalid_step_binding}

  defp validate_legacy_receipt_binding(child, step, receipt) do
    with {:ok, task_contract} <- child |> Grounding.resolve() |> QualityPolicy.build(),
         {:ok, task_digests} <- QualityPolicy.receipt_task_digests(task_contract),
         final_answer when is_binary(final_answer) <-
           child.last_observation_summary || child.progress_summary,
         :ok <-
           QualityReceipt.validate(receipt, %{
             objective_id: child.id,
             step_id: step.id,
             task_contract_sha256: task_digests["2"],
             task_contract_sha256_by_rule_catalog_version: task_digests,
             final_answer: final_answer
           }) do
      :ok
    else
      _invalid -> {:error, :invalid_receipt_binding}
    end
  end

  defp legacy_event_step_id(%Event{payload: payload}) do
    with {:ok, decoded} <- decode_event_payload(payload),
         %{"step_id" => step_id} <- decoded,
         true <- known_legacy_step_payload?(decoded) and is_binary(step_id) do
      {:ok, step_id}
    else
      _invalid -> :none
    end
  end

  defp legacy_event_step_id(_event), do: :none

  defp known_legacy_step_payload?(%{"summary" => summary, "step_id" => step_id} = payload)
       when map_size(payload) == 2,
       do: is_binary(summary) and is_binary(step_id)

  defp known_legacy_step_payload?(
         %{"summary" => summary, "step_id" => step_id, "step_status" => "completed"} = payload
       )
       when map_size(payload) == 3,
       do: is_binary(summary) and is_binary(step_id)

  defp known_legacy_step_payload?(
         %{
           "summary" => summary,
           "step_id" => step_id,
           "step_status" => "completed",
           "quality_receipt" => receipt
         } = payload
       )
       when map_size(payload) == 4,
       do: is_binary(summary) and is_binary(step_id) and is_map(receipt)

  defp known_legacy_step_payload?(_payload), do: false

  defp run_completed_events_by_child(child_ids) do
    Event
    |> where(
      [event],
      event.objective_id in ^child_ids and event.kind == "run_completed"
    )
    |> order_by([event], asc: event.objective_id, asc: event.recorded_at, asc: event.id)
    |> Repo.all()
    |> Enum.group_by(& &1.objective_id)
  end

  defp quality_receipt_event?(%Event{payload: payload}) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = decoded} -> Map.has_key?(decoded, "quality_receipt")
      _invalid -> false
    end
  end

  defp quality_receipt_event?(%Event{payload: payload}) when is_map(payload),
    do: Map.has_key?(payload, "quality_receipt") or Map.has_key?(payload, :quality_receipt)

  defp quality_receipt_event?(_event), do: false

  defp legacy_completion_event?(%Event{payload: payload}, child, step) do
    with {:ok, decoded} <- decode_event_payload(payload) do
      legacy_completion_payload?(decoded, child, step)
    else
      _invalid -> false
    end
  end

  defp legacy_completion_event?(_event, _child, _step), do: false

  defp legacy_completion_payload?(%{"summary" => summary} = payload, child, nil)
       when map_size(payload) == 1 and is_binary(summary),
       do: ordinary_result_summaries_match?(child, nil, summary)

  defp legacy_completion_payload?(
         %{
           "summary" => summary,
           "step_id" => step_id,
           "step_status" => "completed"
         } = payload,
         child,
         %Step{id: step_id, status: "completed"} = step
       )
       when map_size(payload) == 3 and is_binary(summary),
       do: ordinary_result_summaries_match?(child, step, summary)

  defp legacy_completion_payload?(_payload, _child, _step), do: false

  defp ordinary_result_summaries_match?(child, step, event_summary) do
    objective_summary = child.last_observation_summary || child.progress_summary

    is_binary(objective_summary) and
      event_summary == String.slice(objective_summary, 0, 500) and
      (is_nil(step) or step.result_summary == objective_summary)
  end

  defp decode_event_payload(payload) when is_binary(payload), do: Jason.decode(payload)
  defp decode_event_payload(payload) when is_map(payload), do: {:ok, payload}
  defp decode_event_payload(_payload), do: {:error, :invalid_event_payload}

  defp effect_evidence_refs(parent_id) do
    child_ids = Enum.map(children(parent_id), & &1.id)

    Step
    |> where(
      [step],
      step.objective_id in ^child_ids and step.status == "completed" and
        not is_nil(step.candidate_action) and not is_nil(step.trace_id)
    )
    |> order_by([step], asc: step.objective_id, desc: step.updated_at, desc: step.id)
    |> Repo.all()
    |> Enum.reduce(%{}, fn step, refs ->
      Map.put_new(refs, step.objective_id, %{
        kind: "objective_step_trace",
        action: step.candidate_action,
        trace_id: step.trace_id
      })
    end)
  end

  defp v2_effect_evidence_refs(children) do
    current_step_ids =
      children
      |> Enum.map(& &1.current_step_id)
      |> Enum.reject(&is_nil/1)

    Step
    |> where(
      [step],
      step.id in ^current_step_ids and step.status == "completed" and
        not is_nil(step.candidate_action) and step.candidate_action != "direct_answer" and
        not is_nil(step.trace_id)
    )
    |> Repo.all()
    |> Map.new(fn step ->
      {step.objective_id,
       %{
         kind: "objective_step_trace",
         action: step.candidate_action,
         trace_id: step.trace_id
       }}
    end)
  end

  defp context_field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  @doc false
  def receipt_for(kind, parent_id) when kind in [:start, :report] and is_binary(parent_id) do
    :crypto.mac(:hmac, :sha256, ReceiptSecret.ensure!(), "#{kind}:#{parent_id}")
    |> Base.url_encode64(padding: false)
  end

  defp digest(receipt), do: Base.encode16(:crypto.hash(:sha256, receipt), case: :lower)
end
