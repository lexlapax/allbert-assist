defmodule AllbertAssist.Objectives do
  @moduledoc """
  Durable objective runtime facade and store context.

  v0.24 keeps SQLite authoritative. Public lifecycle functions delegate to the
  JidoBacked objective engine; lower-level create/update/list helpers are used
  by that engine as rebuildable storage primitives.
  """

  import Ecto.Query

  alias AllbertAssist.Confirmations.ResumeParamsBinding
  alias AllbertAssist.Objectives.{AcceptanceCriteria, Event, Objective, Step}
  alias AllbertAssist.Objectives.Fanout.TerminalTransitions
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Validation

  @active_statuses ~w[open running blocked]
  @terminal_statuses ~w[completed cancelled failed abandoned]
  @fanout_structural_fields [
    :user_id,
    :source_thread_id,
    :source_channel,
    :source_surface,
    :session_id,
    :active_app,
    :title,
    :objective,
    :acceptance_criteria,
    :constraints,
    :proposer_hint,
    :source_intent,
    :fanout_role,
    :parent_objective_id,
    :join_policy,
    :join_outcome,
    :kickoff_delivery_state,
    :fanout_start_receipt_digest,
    :report_delivery_state,
    :report_delivery_receipt_digest,
    :report_composition_state,
    :report_body,
    :report_source,
    :report_input_digest,
    :origin_thread_ref_id,
    :origin_thread_ref_digest,
    :origin_receiver_account_ref,
    :queue_position,
    :completed_at,
    :run_attempt_count
  ]
  @default_list_limit 50
  @rehydrate_window_seconds 60 * 60
  @known_keys MapSet.new([
                "acceptance_criteria",
                "action_params",
                "active_app",
                "candidate_action",
                "completed_at",
                "confirmation_resume_params_sha256",
                "constraints",
                "current_step_id",
                "delegate_agent_id",
                "id",
                "kind",
                "last_observation_summary",
                "loop_count",
                "objective",
                "objective_id",
                "parent_objective_id",
                "fanout_role",
                "join_policy",
                "join_outcome",
                "kickoff_delivery_state",
                "fanout_start_receipt_digest",
                "report_delivery_state",
                "report_delivery_receipt_digest",
                "report_composition_state",
                "report_body",
                "report_source",
                "report_input_digest",
                "origin_thread_ref_id",
                "origin_thread_ref_digest",
                "origin_receiver_account_ref",
                "queue_position",
                "run_attempt_count",
                "review_reason",
                "parent_step_id",
                "progress_summary",
                "proposer_hint",
                "provider",
                "recorded_at",
                "resource_access",
                "result_summary",
                "session_id",
                "source_channel",
                "source_intent",
                "source_surface",
                "source_thread_id",
                "stage",
                "status",
                "step_id",
                "summary",
                "title",
                "trace_id",
                "user_id",
                "payload"
              ])

  @type objective_result :: {:ok, Objective.t()} | {:error, term()}
  @type step_result :: {:ok, Step.t()} | {:error, term()}
  @type event_result :: {:ok, Event.t()} | {:error, term()}

  @doc "List objectives for a user through the public objective facade."
  @spec list(String.t(), map() | keyword()) :: {:ok, [Objective.t()]}
  def list(user_id, filters \\ %{}) when is_binary(user_id) do
    {:ok, list_objectives(user_id, opts_from(filters))}
  end

  @doc "Fetch one objective for a user through the public objective facade."
  @spec get(String.t(), String.t()) :: objective_result()
  def get(user_id, objective_id) when is_binary(user_id) and is_binary(objective_id) do
    get_objective(user_id, objective_id)
  end

  @doc "Frame a durable objective from an intent decision and request context."
  @spec frame(map(), map()) :: {:ok, map()} | {:error, term()}
  def frame(intent_decision, context \\ %{}) when is_map(intent_decision) and is_map(context) do
    with :ok <- validate_effect_context(context),
         {:ok, user_id} <- facade_user_id(intent_decision, context) do
      AllbertAssist.Objectives.Engine.Agent.frame_objective(%{
        user_id: user_id,
        source_thread_id:
          facade_field(intent_decision, :thread_id) || facade_field(context, :thread_id),
        source_channel:
          facade_field(intent_decision, :channel) || facade_field(context, :channel),
        source_surface:
          facade_field(intent_decision, :surface) || facade_field(context, :surface),
        session_id:
          facade_field(intent_decision, :session_id) || facade_field(context, :session_id),
        active_app:
          facade_field(intent_decision, :active_app) || facade_field(context, :active_app),
        title: objective_title(intent_decision),
        objective: objective_text(intent_decision),
        acceptance_criteria: facade_field(intent_decision, :acceptance_criteria),
        constraints: facade_field(intent_decision, :constraints),
        source_intent:
          facade_field(intent_decision, :text) || facade_field(intent_decision, :intent),
        allbert_pack_epoch: facade_field(context, :allbert_pack_epoch)
      })
    end
  end

  @doc "Advance the current step for an objective through the engine."
  @spec advance(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def advance(objective_id, event \\ %{}) when is_binary(objective_id) and is_map(event) do
    with :ok <- validate_effect_context(event) do
      AllbertAssist.Objectives.Engine.Agent.advance_objective(%{
        objective_id: objective_id,
        trace_id: facade_field(event, :trace_id),
        allbert_pack_epoch: facade_field(event, :allbert_pack_epoch)
      })
    end
  end

  @doc "Cancel an objective through the engine."
  @spec cancel(String.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def cancel(user_id, objective_id, reason, context)
      when is_binary(user_id) and is_binary(objective_id) and is_binary(reason) and
             is_map(context) do
    with :ok <- validate_effect_context(context) do
      AllbertAssist.Objectives.Engine.Agent.cancel_objective(%{
        id: objective_id,
        user_id: user_id,
        reason: reason,
        allbert_pack_epoch: facade_field(context, :allbert_pack_epoch)
      })
    end
  end

  @spec cancel(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def cancel(user_id, objective_id, reason)
      when is_binary(user_id) and is_binary(objective_id) and is_binary(reason) do
    {:error, :product_not_ready}
  end

  @doc "Durably mark an owned active objective as awaiting cancellation cleanup."
  @spec request_cancellation(String.t(), String.t(), String.t(), map()) :: objective_result()
  def request_cancellation(user_id, objective_id, reason, context)
      when is_binary(user_id) and is_binary(objective_id) and is_binary(reason) and
             is_map(context) do
    with :ok <- validate_effect_context(context) do
      now = DateTime.utc_now()

      query =
        from objective in Objective,
          where:
            objective.id == ^objective_id and objective.user_id == ^user_id and
              objective.status in ^@active_statuses and
              not (objective.status == "blocked" and
                     objective.review_reason == "cancellation_requested")

      transaction = fn ->
        request_cancellation_transaction(query, user_id, objective_id, reason, now, context)
      end

      case Repo.transaction(transaction) do
        {:ok, objective} -> {:ok, objective}
        {:error, transaction_error} -> {:error, transaction_error}
      end
    end
  end

  @spec request_cancellation(String.t(), String.t(), String.t()) :: objective_result()
  def request_cancellation(user_id, objective_id, reason)
      when is_binary(user_id) and is_binary(objective_id) and is_binary(reason) do
    {:error, :product_not_ready}
  end

  defp request_cancellation_transaction(query, user_id, objective_id, reason, now, context) do
    updates = [
      status: "blocked",
      review_reason: "cancellation_requested",
      updated_at: now
    ]

    case Repo.update_all(query, set: updates) do
      {1, _rows} -> persist_cancellation_request(user_id, objective_id, reason, context)
      {0, _rows} -> existing_cancellation_request(user_id, objective_id)
    end
  end

  defp persist_cancellation_request(user_id, objective_id, reason, context) do
    objective = Repo.get_by!(Objective, id: objective_id, user_id: user_id)

    case create_event(
           %{
             objective_id: objective_id,
             kind: "run_blocked",
             summary: "Objective cancellation requested",
             payload: %{reason: reason}
           },
           context
         ) do
      {:ok, _event} ->
        if validate_effect_context(context) == :ok,
          do: objective,
          else: Repo.rollback(:product_not_ready)

      {:error, event_error} ->
        Repo.rollback(event_error)
    end
  end

  defp existing_cancellation_request(user_id, objective_id) do
    case Repo.get_by(Objective, id: objective_id, user_id: user_id) do
      %Objective{status: "blocked", review_reason: "cancellation_requested"} = objective ->
        objective

      %Objective{status: status} ->
        Repo.rollback({:objective_not_cancellable, status})

      nil ->
        Repo.rollback(:not_found)
    end
  end

  @doc "Continue an objective through the engine with the originating exact readiness epoch."
  @spec continue(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def continue(user_id, objective_id, context)
      when is_binary(user_id) and is_binary(objective_id) and is_map(context) do
    with :ok <- validate_effect_context(context) do
      AllbertAssist.Objectives.Engine.Agent.continue_objective(%{
        id: objective_id,
        user_id: user_id,
        allbert_pack_epoch: facade_field(context, :allbert_pack_epoch)
      })
    end
  end

  @spec continue(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def continue(user_id, objective_id) when is_binary(user_id) and is_binary(objective_id),
    do: {:error, :product_not_ready}

  @doc "Generate an opaque objective-system id."
  @spec new_id(String.t()) :: String.t()
  def new_id(prefix) when is_binary(prefix), do: prefix <> "_" <> Ecto.UUID.generate()

  @doc false
  @spec normalize_channel(term()) :: String.t() | nil
  def normalize_channel(nil), do: nil
  def normalize_channel(%{name: name}), do: normalize_channel(name)
  def normalize_channel(%{"name" => name}), do: normalize_channel(name)
  def normalize_channel(channel) when is_atom(channel), do: Atom.to_string(channel)
  def normalize_channel(channel) when is_binary(channel) and channel != "", do: channel
  def normalize_channel(_channel), do: nil

  @doc "Create an objective with the caller's exact readiness epoch."
  @spec create_objective(map(), map()) :: objective_result()
  def create_objective(attrs, context) when is_map(attrs) and is_map(context) do
    attrs =
      attrs
      |> atomize_known()
      |> Map.put_new(:id, new_id("obj"))
      |> Map.put_new(:status, "open")
      |> update_if_present(:source_channel, &normalize_channel/1)
      |> Map.update(:acceptance_criteria, nil, &encode_jsonish/1)
      |> Map.update(:proposer_hint, nil, &encode_jsonish/1)

    with :ok <- validate_effect_context(context) do
      %Objective{}
      |> Objective.changeset(attrs)
      |> insert_with_effect_context(context)
    end
  end

  # Durable Objective writes are effects. Deliberately do not admit a new epoch
  # here: callers must carry the E1 that admitted their enclosing effect.
  @spec create_objective(map()) :: objective_result()
  def create_objective(attrs) when is_map(attrs), do: {:error, :product_not_ready}

  @doc "Update an objective with the caller's exact readiness epoch."
  @spec update_objective(Objective.t(), map(), map()) :: objective_result()
  def update_objective(%Objective{} = objective, attrs, context)
      when is_map(attrs) and is_map(context) do
    attrs =
      attrs
      |> atomize_known()
      |> update_if_present(:source_channel, &normalize_channel/1)
      |> update_if_present(:acceptance_criteria, &encode_jsonish/1)
      |> update_if_present(:proposer_hint, &encode_jsonish/1)

    with :ok <- authorize_objective_update(objective, attrs) do
      if objective.fanout_role == "child" do
        update_active_fanout_child(objective, attrs, context)
      else
        objective
        |> Objective.changeset(attrs)
        |> update_with_effect_context(context)
      end
    end
  end

  @spec update_objective(Objective.t(), map()) :: objective_result()
  def update_objective(%Objective{}, attrs) when is_map(attrs), do: {:error, :product_not_ready}

  defp authorize_objective_update(
         %Objective{fanout_role: "child", status: status},
         _attrs
       )
       when status in @terminal_statuses,
       do: {:error, :fanout_terminal_immutable}

  defp authorize_objective_update(%Objective{fanout_role: "child"}, attrs) do
    cond do
      Map.has_key?(attrs, :status) ->
        {:error, :fanout_active_transition_required}

      Enum.any?(@fanout_structural_fields, &Map.has_key?(attrs, &1)) ->
        {:error, :fanout_structure_immutable}

      true ->
        :ok
    end
  end

  defp authorize_objective_update(%Objective{fanout_role: "parent"}, _attrs),
    do: {:error, :fanout_parent_transition_required}

  defp authorize_objective_update(%Objective{}, _attrs), do: :ok

  defp update_active_fanout_child(objective, attrs, context) do
    objective
    |> Objective.changeset(attrs)
    |> persist_active_fanout_child(objective, context)
  end

  defp persist_active_fanout_child(
         %Ecto.Changeset{valid?: false} = changeset,
         _objective,
         _context
       ),
       do: {:error, changeset}

  defp persist_active_fanout_child(%Ecto.Changeset{changes: changes}, objective, _context)
       when map_size(changes) == 0,
       do: {:ok, objective}

  defp persist_active_fanout_child(changeset, objective, context) do
    updates =
      changeset.changes
      |> Map.put(:updated_at, DateTime.utc_now())
      |> Map.to_list()

    with :ok <- validate_effect_context(context) do
      objective
      |> active_fanout_child_query()
      |> Repo.update_all(set: updates)
      |> active_fanout_child_update_result(objective.id)
    end
  end

  defp active_fanout_child_query(objective) do
    from current in Objective,
      where:
        current.id == ^objective.id and current.fanout_role == "child" and
          current.status in ^@active_statuses and
          current.updated_at == ^objective.updated_at
  end

  defp active_fanout_child_update_result({1, _rows}, objective_id),
    do: {:ok, Repo.get!(Objective, objective_id)}

  defp active_fanout_child_update_result({0, _rows}, objective_id) do
    current = Repo.get(Objective, objective_id)
    {:error, {:fanout_active_compare_and_set_failed, current && current.status}}
  end

  @doc "Fetch an objective by id."
  @spec get_objective(String.t()) :: objective_result()
  def get_objective(id) when is_binary(id) do
    case Repo.get(Objective, id) do
      %Objective{} = objective -> {:ok, objective}
      nil -> {:error, {:objective_not_found, id}}
    end
  end

  @doc "Fetch an objective scoped to a user id."
  @spec get_objective(String.t(), String.t()) :: objective_result()
  def get_objective(user_id, id) when is_binary(user_id) and is_binary(id) do
    query =
      from objective in Objective, where: objective.user_id == ^user_id and objective.id == ^id

    case Repo.one(query) do
      %Objective{} = objective -> {:ok, objective}
      nil -> {:error, :not_found}
    end
  end

  @doc "List objectives scoped to a user id."
  @spec list_objectives(String.t(), keyword()) :: [Objective.t()]
  def list_objectives(user_id, opts \\ []) when is_binary(user_id) and is_list(opts) do
    limit = normalize_limit(Keyword.get(opts, :limit), @default_list_limit, 100)
    statuses = Keyword.get(opts, :status) || Keyword.get(opts, :statuses)
    active_app = Keyword.get(opts, :active_app)
    source_thread_id = Keyword.get(opts, :source_thread_id)
    source_intent = Keyword.get(opts, :source_intent)

    Objective
    |> where([objective], objective.user_id == ^user_id)
    |> maybe_filter_statuses(statuses)
    |> maybe_filter(:active_app, active_app)
    |> maybe_filter(:source_thread_id, source_thread_id)
    |> maybe_filter(:source_intent, source_intent)
    |> order_by([objective], desc: objective.updated_at, desc: objective.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc false
  @spec control_objectives(String.t(), keyword()) :: [Objective.t()]
  def control_objectives(user_id, opts \\ []) when is_binary(user_id) and is_list(opts) do
    Objective
    |> where(
      [objective],
      objective.user_id == ^user_id and objective.status in ^@active_statuses
    )
    |> maybe_filter(:source_thread_id, Keyword.get(opts, :source_thread_id))
    |> maybe_filter(:session_id, Keyword.get(opts, :session_id))
    |> maybe_filter(:fanout_role, Keyword.get(opts, :fanout_role))
    |> order_by([objective], desc: objective.updated_at, desc: objective.inserted_at)
    |> Repo.all()
  end

  @doc "Find the newest active objective for a user and source intent marker."
  @spec find_active_by_source_intent(String.t(), String.t()) :: objective_result()
  def find_active_by_source_intent(user_id, source_intent)
      when is_binary(user_id) and is_binary(source_intent) do
    case list_objectives(user_id,
           statuses: @active_statuses,
           source_intent: source_intent,
           limit: 1
         ) do
      [%Objective{} = objective | _rest] -> {:ok, objective}
      [] -> {:error, :not_found}
    end
  end

  @doc "Return active objectives eligible for JidoBacked rehydration."
  @spec active_objectives(keyword()) :: [Objective.t()]
  def active_objectives(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    window_seconds = Keyword.get(opts, :window_seconds, @rehydrate_window_seconds)
    cutoff = DateTime.add(now, -window_seconds, :second)

    Objective
    |> where([objective], objective.status in ^@active_statuses)
    |> where([objective], objective.updated_at >= ^cutoff)
    |> order_by([objective], asc: objective.updated_at)
    |> Repo.all()
  end

  @doc "Mark stale active objectives abandoned and return the count."
  @spec abandon_stale_objectives(keyword(), map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def abandon_stale_objectives(opts, context) when is_list(opts) and is_map(context) do
    with :ok <- validate_effect_context(context) do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      window_seconds = Keyword.get(opts, :window_seconds, @rehydrate_window_seconds)
      cutoff = DateTime.add(now, -window_seconds, :second)

      stale =
        Objective
        |> where([objective], objective.status in ^@active_statuses)
        |> where([objective], objective.updated_at < ^cutoff)

      ordinary_query = where(stale, [objective], is_nil(objective.fanout_role))

      with {:ok, ordinary_count} <-
             Repo.transaction(fn ->
               {count, _} =
                 Repo.update_all(ordinary_query, set: [status: "abandoned", updated_at: now])

               validate_effect_context_or_rollback!(context)
               count
             end) do
        stale_children =
          stale
          |> where([objective], objective.fanout_role == "child")
          |> join(:inner, [child], parent in Objective,
            on:
              parent.id == child.parent_objective_id and parent.fanout_role == "parent" and
                parent.kickoff_delivery_state == "acknowledged" and
                parent.report_delivery_state == "not_ready"
          )
          |> order_by([objective],
            asc: objective.parent_objective_id,
            asc: objective.queue_position
          )
          |> select([child, _parent], child)
          |> Repo.all()

        case abandon_stale_fanout_children(stale_children, cutoff, now, context) do
          {:ok, child_count} -> {:ok, ordinary_count + child_count}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  def abandon_stale_objectives(_opts), do: {:error, :product_not_ready}
  def abandon_stale_objectives, do: {:error, :product_not_ready}

  defp abandon_stale_fanout_children(children, cutoff, now, context) do
    Enum.reduce_while(children, {:ok, 0}, fn child, {:ok, count} ->
      case TerminalTransitions.terminalize_child(
             child,
             %{
               status: "abandoned",
               progress_summary: "Abandoned after exceeding the recovery window.",
               review_reason: "stale_recovery_window_exceeded",
               completed_at: now
             },
             "run_abandoned",
             %{reason: "stale_recovery_window_exceeded"},
             updated_before: cutoff,
             signal: {:run_abandoned, %{reason: "stale_recovery_window_exceeded"}},
             effect_context: context
           ) do
        {:ok, _transition} ->
          {:cont, {:ok, count + 1}}

        {:error, {:objective_not_terminalizable, _status}} ->
          {:cont, {:ok, count}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Create a step with the caller's exact readiness epoch."
  @spec create_step(map(), map()) :: step_result()
  def create_step(attrs, context) when is_map(attrs) and is_map(context) do
    attrs =
      attrs
      |> atomize_known()
      |> Map.put_new(:id, new_id("step"))
      |> Map.put_new(:status, "proposed")
      |> normalize_step_fields()
      |> Map.update(:action_params, nil, &encode_jsonish/1)
      |> Map.update(:resource_access, nil, &encode_jsonish/1)

    with :ok <- authorize_step_write(Map.get(attrs, :objective_id)),
         :ok <- validate_effect_context(context) do
      %Step{}
      |> Step.changeset(attrs)
      |> insert_with_effect_context(context)
    end
  end

  @spec create_step(map()) :: step_result()
  def create_step(attrs) when is_map(attrs), do: {:error, :product_not_ready}

  @doc "Update a step with the caller's exact readiness epoch."
  @spec update_step(Step.t(), map(), map()) :: step_result()
  def update_step(%Step{} = step, attrs, context) when is_map(attrs) and is_map(context) do
    attrs =
      attrs
      |> atomize_known()
      |> normalize_step_fields()
      |> update_if_present(:action_params, &encode_jsonish/1)
      |> update_if_present(:resource_access, &encode_jsonish/1)

    with :ok <- authorize_step_write(step.objective_id),
         :ok <- validate_effect_context(context) do
      step
      |> Step.changeset(attrs)
      |> update_with_effect_context(context)
    end
  end

  @spec update_step(Step.t(), map()) :: step_result()
  def update_step(%Step{}, attrs) when is_map(attrs), do: {:error, :product_not_ready}

  @doc "Transition a step with the caller's exact readiness epoch."
  @spec transition_step(Step.t(), String.t() | atom(), map(), map()) :: step_result()
  def transition_step(%Step{} = step, status, attrs, context)
      when is_map(attrs) and is_map(context) do
    update_step(step, Map.merge(attrs, %{status: normalize_string(status)}), context)
  end

  @spec transition_step(Step.t(), String.t() | atom(), map()) :: step_result()
  def transition_step(%Step{}, _status, attrs) when is_map(attrs),
    do: {:error, :product_not_ready}

  @spec transition_step(Step.t(), String.t() | atom()) :: step_result()
  def transition_step(%Step{}, _status), do: {:error, :product_not_ready}

  defp authorize_step_write(objective_id) when is_binary(objective_id) do
    query =
      from child in Objective,
        join: parent in Objective,
        on: parent.id == child.parent_objective_id,
        where:
          child.id == ^objective_id and child.fanout_role == "child" and
            parent.fanout_role == "parent" and parent.report_composition_state != "not_ready",
        or_where:
          child.id == ^objective_id and child.fanout_role == "child" and
            parent.fanout_role == "parent" and parent.report_delivery_state != "not_ready",
        select: true

    if Repo.exists?(query), do: {:error, :fanout_report_input_frozen}, else: :ok
  end

  defp authorize_step_write(_objective_id), do: :ok

  @doc "List steps for an objective."
  @spec list_steps(String.t()) :: [Step.t()]
  def list_steps(objective_id) when is_binary(objective_id) do
    Step
    |> where([step], step.objective_id == ^objective_id)
    |> order_by([step], asc: step.inserted_at, asc: step.id)
    |> Repo.all()
  end

  @doc "Resolve durable confirmation provenance to its unique fan-out child and step."
  @spec fanout_confirmation_target(map() | String.t()) ::
          {:ok,
           %{
             child: Objective.t(),
             step: Step.t(),
             parent_id: String.t(),
             phase: :binding | :bound
           }}
          | {:error,
             :not_fanout_confirmation
             | :stale_fanout_confirmation
             | :ambiguous_confirmation_target
             | term()}
  def fanout_confirmation_target(%{} = confirmation) do
    fanout_confirmation_target(confirmation, [])
  end

  def fanout_confirmation_target(confirmation_id)
      when is_binary(confirmation_id) and confirmation_id != "" do
    fanout_confirmation_target_by_id(confirmation_id, %{})
  end

  def fanout_confirmation_target(_missing), do: {:error, :not_fanout_confirmation}

  @doc false
  @spec fanout_confirmation_target(map(), keyword()) ::
          {:ok,
           %{
             child: Objective.t(),
             step: Step.t(),
             parent_id: String.t(),
             phase: :binding | :bound
           }}
          | {:error, term()}
  def fanout_confirmation_target(%{} = confirmation, opts) when is_list(opts) do
    origin = facade_field(confirmation, :origin) || %{}
    target_action = facade_field(confirmation, :target_action) || %{}

    resolve_fanout_confirmation_binding(%{
      confirmation_id: facade_field(confirmation, :id),
      objective_id: facade_field(confirmation, :objective_id),
      step_id: facade_field(confirmation, :step_id),
      binding_version: facade_field(confirmation, :objective_binding_version),
      binding_kind: facade_field(confirmation, :objective_binding_kind),
      parent_objective_id: fanout_parent_marker(confirmation),
      target_action_name: facade_field(target_action, :name),
      origin_user_id: facade_field(origin, :user_id),
      resume_params_ref: facade_field(confirmation, :resume_params_ref),
      verify_resume_binding?: Keyword.get(opts, :verify_resume_binding?, true)
    })
  end

  defp fanout_confirmation_target_by_id(confirmation_id, expectations)
       when is_binary(confirmation_id) and confirmation_id != "" do
    steps =
      Step
      |> where([step], step.confirmation_id == ^confirmation_id)
      |> limit(2)
      |> Repo.all()

    case steps do
      [%Step{} = step] ->
        fanout_confirmation_target_by_provenance(
          confirmation_id,
          step.objective_id,
          step.id,
          expectations
        )

      [] ->
        {:error, :not_fanout_confirmation}

      [_first, _second] ->
        {:error, :ambiguous_confirmation_target}
    end
  end

  defp fanout_confirmation_target_by_id(_missing, _expectations),
    do: {:error, :not_fanout_confirmation}

  defp resolve_fanout_confirmation_binding(%{binding_version: 2} = binding),
    do: resolve_current_fanout_binding(binding)

  defp resolve_fanout_confirmation_binding(%{binding_version: 1} = binding),
    do: resolve_candidate_v1_fanout_binding(binding)

  defp resolve_fanout_confirmation_binding(%{binding_version: nil} = binding),
    do: resolve_legacy_fanout_binding(binding)

  defp resolve_fanout_confirmation_binding(%{}),
    do: {:error, :stale_fanout_confirmation}

  defp resolve_current_fanout_binding(%{
         binding_kind: "objective",
         confirmation_id: confirmation_id,
         objective_id: objective_id,
         step_id: step_id,
         parent_objective_id: nil
       })
       when is_binary(confirmation_id) and confirmation_id != "" and is_binary(objective_id) and
              objective_id != "" and is_binary(step_id) and step_id != "" do
    objective_confirmation_target_by_provenance(confirmation_id, objective_id, step_id)
  end

  defp resolve_current_fanout_binding(
         %{
           binding_kind: "fanout_child",
           confirmation_id: confirmation_id,
           objective_id: objective_id,
           step_id: step_id,
           parent_objective_id: parent_objective_id
         } = binding
       )
       when is_binary(confirmation_id) and confirmation_id != "" and is_binary(objective_id) and
              objective_id != "" and is_binary(step_id) and step_id != "" and
              is_binary(parent_objective_id) do
    fanout_confirmation_target_by_provenance(
      confirmation_id,
      objective_id,
      step_id,
      binding_expectations(binding, true)
    )
  end

  defp resolve_current_fanout_binding(%{
         binding_kind: "ordinary",
         objective_id: objective_id,
         step_id: step_id,
         parent_objective_id: nil
       }) do
    if complete_confirmation_provenance?(objective_id, step_id),
      do: {:error, :stale_fanout_confirmation},
      else: {:error, :not_fanout_confirmation}
  end

  defp resolve_current_fanout_binding(%{}), do: {:error, :stale_fanout_confirmation}

  # The short-lived local v1 transition records predate the explicit binding
  # kind. Preserve their decision rule: complete objective/step provenance
  # receives durable classification even when the parent marker is absent;
  # incomplete parent-marked records fail closed; all other v1 records are
  # ordinary.
  defp resolve_candidate_v1_fanout_binding(
         %{
           binding_kind: nil,
           confirmation_id: confirmation_id,
           objective_id: objective_id,
           step_id: step_id
         } = binding
       )
       when is_binary(confirmation_id) and confirmation_id != "" and is_binary(objective_id) and
              objective_id != "" and is_binary(step_id) and step_id != "" do
    fanout_confirmation_target_by_provenance(
      confirmation_id,
      objective_id,
      step_id,
      binding_expectations(binding, false)
    )
  end

  defp resolve_candidate_v1_fanout_binding(%{
         binding_kind: nil,
         parent_objective_id: nil
       }),
       do: {:error, :not_fanout_confirmation}

  defp resolve_candidate_v1_fanout_binding(%{}), do: {:error, :stale_fanout_confirmation}

  # The first M12.15 candidate wrote complete child/step provenance without a
  # binding version. Preserve that real on-disk shape before considering the
  # older confirmation-id-only recovery path. Durable rows, not the record's
  # unversioned metadata, still decide whether the target is a valid fan-out
  # child and whether its action, owner, parent, and phase agree.
  defp resolve_legacy_fanout_binding(
         %{
           binding_kind: nil,
           confirmation_id: confirmation_id,
           objective_id: objective_id,
           step_id: step_id
         } = binding
       )
       when is_binary(confirmation_id) and confirmation_id != "" and is_binary(objective_id) and
              objective_id != "" and is_binary(step_id) and step_id != "" do
    fanout_confirmation_target_by_provenance(
      confirmation_id,
      objective_id,
      step_id,
      binding_expectations(binding, false)
    )
  end

  defp resolve_legacy_fanout_binding(%{binding_kind: nil} = binding) do
    if legacy_fanout_child_marker?(binding.objective_id) or
         present_binding?(binding.parent_objective_id) do
      {:error, :stale_fanout_confirmation}
    else
      fanout_confirmation_target_by_id(
        binding.confirmation_id,
        binding_expectations(binding, false)
      )
    end
  end

  defp resolve_legacy_fanout_binding(%{}), do: {:error, :stale_fanout_confirmation}

  defp complete_confirmation_provenance?(objective_id, step_id) do
    is_binary(objective_id) and objective_id != "" and is_binary(step_id) and step_id != ""
  end

  defp present_binding?(value), do: is_binary(value) and value != ""

  defp binding_expectations(binding, required?) do
    %{
      parent_objective_id: Map.get(binding, :parent_objective_id),
      target_action_name: Map.get(binding, :target_action_name),
      user_id: Map.get(binding, :origin_user_id),
      resume_params_ref: Map.get(binding, :resume_params_ref),
      verify_resume_binding?: Map.get(binding, :verify_resume_binding?, false),
      required?: required?
    }
  end

  defp objective_confirmation_target_by_provenance(confirmation_id, objective_id, step_id) do
    with %Objective{} = objective <- Repo.get(Objective, objective_id),
         %Step{} = step <- Enum.find(list_steps(objective_id), &(&1.id == step_id)),
         :ok <- verify_unique_confirmation_step(confirmation_id, step) do
      case objective do
        %Objective{fanout_role: "child"} -> {:error, :stale_fanout_confirmation}
        %Objective{} -> {:error, :not_fanout_confirmation}
      end
    else
      nil -> {:error, :stale_fanout_confirmation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fanout_confirmation_target_by_provenance(
         confirmation_id,
         objective_id,
         step_id,
         expectations
       ) do
    with %Objective{} = child <- Repo.get(Objective, objective_id),
         %Step{} = step <- Enum.find(list_steps(objective_id), &(&1.id == step_id)),
         :ok <- verify_unique_confirmation_step(confirmation_id, step),
         :ok <-
           verify_fanout_parent_marker(child, Map.get(expectations, :parent_objective_id)),
         :ok <- verify_confirmation_target_metadata(child, step, expectations) do
      classify_fanout_confirmation_target(confirmation_id, child, step)
    else
      nil -> {:error, :stale_fanout_confirmation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_fanout_parent_marker(_child, nil), do: :ok

  defp verify_fanout_parent_marker(%Objective{parent_objective_id: parent_id}, parent_id),
    do: :ok

  defp verify_fanout_parent_marker(%Objective{}, _expected_parent_id),
    do: {:error, :stale_fanout_confirmation}

  defp verify_confirmation_target_metadata(child, step, expectations) do
    with :ok <-
           verify_expected_binding(
             step.candidate_action,
             Map.get(expectations, :target_action_name),
             Map.get(expectations, :required?, false)
           ),
         :ok <-
           verify_expected_binding(
             child.user_id,
             Map.get(expectations, :user_id),
             Map.get(expectations, :required?, false)
           ),
         :ok <- verify_confirmation_resume_binding(step, expectations) do
      :ok
    end
  end

  defp verify_confirmation_resume_binding(
         %Step{},
         %{verify_resume_binding?: false}
       ),
       do: :ok

  defp verify_confirmation_resume_binding(
         %Step{confirmation_resume_params_sha256: nil},
         _expectations
       ),
       do: :ok

  defp verify_confirmation_resume_binding(
         %Step{confirmation_resume_params_sha256: expected},
         expectations
       ) do
    case ResumeParamsBinding.verify(expected, Map.get(expectations, :resume_params_ref)) do
      :ok -> :ok
      {:error, _reason} -> {:error, :confirmation_resume_params_mismatch}
    end
  end

  defp verify_expected_binding(actual, expected, _required?)
       when is_binary(expected) and expected != "" and actual == expected,
       do: :ok

  defp verify_expected_binding(_actual, expected, false) when expected in [nil, ""], do: :ok

  defp verify_expected_binding(_actual, _expected, _required?),
    do: {:error, :stale_fanout_confirmation}

  defp verify_unique_confirmation_step(confirmation_id, step) do
    linked_steps =
      Step
      |> where([candidate], candidate.confirmation_id == ^confirmation_id)
      |> select([candidate], {candidate.objective_id, candidate.id})
      |> limit(2)
      |> Repo.all()

    case linked_steps do
      [] ->
        :ok

      [{objective_id, step_id}] when objective_id == step.objective_id and step_id == step.id ->
        :ok

      _other ->
        {:error, :ambiguous_confirmation_target}
    end
  end

  defp classify_fanout_confirmation_target(
         confirmation_id,
         %Objective{fanout_role: "child", parent_objective_id: parent_id} = child,
         %Step{} = step
       )
       when is_binary(parent_id) do
    phase = fanout_confirmation_phase(confirmation_id, child, step)
    parent = Repo.get(Objective, parent_id)
    classify_fanout_confirmation_parent(phase, parent, child, step, parent_id)
  end

  defp classify_fanout_confirmation_target(_confirmation_id, %Objective{}, %Step{}),
    do: {:error, :not_fanout_confirmation}

  defp fanout_confirmation_phase(confirmation_id, child, step) do
    cond do
      bound_fanout_confirmation?(confirmation_id, child, step) -> :bound
      binding_fanout_confirmation?(confirmation_id, child, step) -> :binding
      true -> :stale
    end
  end

  defp bound_fanout_confirmation?(confirmation_id, child, step) do
    child.status == "blocked" and child.current_step_id == step.id and
      step.status == "blocked" and step.confirmation_id == confirmation_id
  end

  defp binding_fanout_confirmation?(confirmation_id, child, step) do
    child.status in ~w[open running] and
      step.status not in ~w[completed failed cancelled skipped] and
      step.confirmation_id in [nil, confirmation_id]
  end

  defp classify_fanout_confirmation_parent(
         phase,
         %Objective{
           fanout_role: "parent",
           report_delivery_state: "not_ready",
           user_id: user_id
         },
         %Objective{user_id: user_id} = child,
         step,
         parent_id
       )
       when phase in [:binding, :bound],
       do: {:ok, %{child: child, step: step, parent_id: parent_id, phase: phase}}

  defp classify_fanout_confirmation_parent(_phase, _parent, _child, _step, _parent_id),
    do: {:error, :stale_fanout_confirmation}

  defp fanout_parent_marker(confirmation) do
    origin = facade_field(confirmation, :origin) || %{}
    parent_id = facade_field(origin, :parent_objective_id)

    if is_binary(parent_id) and parent_id != "", do: parent_id
  end

  defp legacy_fanout_child_marker?(objective_id)
       when is_binary(objective_id) and objective_id != "",
       do: match?(%Objective{fanout_role: "child"}, Repo.get(Objective, objective_id))

  defp legacy_fanout_child_marker?(_objective_id), do: false

  @doc "Create an event with the caller's exact readiness epoch."
  @spec create_event(map(), map()) :: event_result()
  def create_event(attrs, context) when is_map(attrs) and is_map(context) do
    attrs =
      attrs
      |> atomize_known()
      |> Map.put_new(:id, new_id("evt"))
      |> Map.put_new(:recorded_at, DateTime.utc_now())
      |> Map.update(:payload, nil, &encode_event_payload/1)

    with :ok <- validate_effect_context(context) do
      %Event{}
      |> Event.changeset(attrs)
      |> insert_with_effect_context(context)
    end
  end

  @spec create_event(map()) :: event_result()
  def create_event(attrs) when is_map(attrs), do: {:error, :product_not_ready}

  # Keep the final validation physically adjacent to each Repo mutation. This
  # prevents an E2 replacement from being silently admitted between a caller's
  # E1 admission and the durable write.
  defp insert_with_effect_context(changeset, context) do
    with :ok <- validate_effect_context(context), do: Repo.insert(changeset)
  end

  defp update_with_effect_context(changeset, context) do
    with :ok <- validate_effect_context(context), do: Repo.update(changeset)
  end

  @doc false
  @spec validate_effect_context(map()) :: :ok | {:error, :product_not_ready | :stale_epoch}
  def validate_effect_context(%{allbert_pack_epoch: epoch}), do: EffectGuard.validate(epoch)

  def validate_effect_context(_context), do: {:error, :product_not_ready}

  defp validate_effect_context_or_rollback!(context) do
    case validate_effect_context(context) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc "List recent events for an objective."
  @spec list_events(String.t()) :: [Event.t()]
  @spec list_events(String.t(), keyword()) :: [Event.t()]
  @spec list_events(keyword()) :: [Event.t()]

  def list_events(objective_id) when is_binary(objective_id), do: list_events(objective_id, [])

  def list_events(opts) when is_list(opts) do
    limit = normalize_limit(Keyword.get(opts, :limit), 50, 200)
    user_id = Keyword.get(opts, :user_id)
    active_app = Keyword.get(opts, :active_app)
    kind = Keyword.get(opts, :kind)

    Event
    |> join(:inner, [event], objective in Objective, on: objective.id == event.objective_id)
    |> maybe_filter_event_user(user_id)
    |> maybe_filter_event_app(active_app)
    |> maybe_filter_event_kind(kind)
    |> order_by([event, _objective], desc: event.recorded_at, desc: event.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_events(objective_id, opts) when is_binary(objective_id) do
    limit = normalize_limit(Keyword.get(opts, :limit), 50, 200)

    Event
    |> where([event], event.objective_id == ^objective_id)
    |> order_by([event], desc: event.recorded_at, desc: event.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Return the decoded acceptance criteria for an objective."
  @spec acceptance_criteria(Objective.t()) :: {:ok, map() | nil} | {:error, term()}
  def acceptance_criteria(%Objective{acceptance_criteria: criteria}) do
    AcceptanceCriteria.decode(criteria)
  end

  @doc "Return a bounded map safe for traces and signals."
  @spec objective_summary(Objective.t()) :: map()
  def objective_summary(%Objective{} = objective) do
    %{
      id: objective.id,
      user_id: objective.user_id,
      source_thread_id: objective.source_thread_id,
      active_app: objective.active_app,
      status: objective.status,
      title: objective.title,
      current_step_id: objective.current_step_id,
      loop_count: objective.loop_count
    }
    |> Redactor.redact()
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, field, value), do: where(query, [row], field(row, ^field) == ^value)

  defp maybe_filter_event_user(query, nil), do: query

  defp maybe_filter_event_user(query, user_id) do
    where(query, [_event, objective], objective.user_id == ^user_id)
  end

  defp maybe_filter_event_app(query, nil), do: query

  defp maybe_filter_event_app(query, active_app) do
    where(query, [_event, objective], objective.active_app == ^active_app)
  end

  defp maybe_filter_event_kind(query, nil), do: query

  defp maybe_filter_event_kind(query, kind) do
    where(query, [event, _objective], event.kind == ^to_string(kind))
  end

  defp maybe_filter_statuses(query, nil), do: query

  defp maybe_filter_statuses(query, statuses) do
    statuses = statuses |> List.wrap() |> Enum.map(&normalize_string/1)
    where(query, [objective], objective.status in ^statuses)
  end

  defp normalize_limit(nil, default, _max), do: default

  defp normalize_limit(limit, _default, max) when is_integer(limit),
    do: Validation.clamp_limit(limit, 1, max)

  defp normalize_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} -> normalize_limit(parsed, default, max)
      _ -> default
    end
  end

  defp normalize_limit(_limit, default, _max), do: default

  defp opts_from(filters) when is_list(filters), do: filters

  defp opts_from(filters) when is_map(filters) do
    [:limit, :status, :statuses, :active_app, :source_thread_id, :source_intent]
    |> Enum.flat_map(fn key ->
      case facade_field(filters, key) do
        nil -> []
        value -> [{key, value}]
      end
    end)
  end

  defp objective_title(intent_decision) do
    intent_decision
    |> facade_field(:title)
    |> case do
      value when is_binary(value) and value != "" -> value
      _other -> objective_text(intent_decision) |> String.slice(0, 120)
    end
  end

  defp objective_text(intent_decision) do
    (facade_field(intent_decision, :objective) ||
       facade_field(intent_decision, :text) ||
       facade_field(intent_decision, :intent) ||
       "Objective")
    |> to_string()
  end

  defp facade_field(map, key) when is_map(map) do
    AllbertAssist.Maps.field_truthy(map, key)
  end

  defp facade_user_id(intent_decision, context) do
    user_id = facade_field(intent_decision, :user_id) || facade_field(context, :user_id)

    case user_id do
      value when is_binary(value) ->
        value = String.trim(value)

        if value == "" do
          {:error, :missing_user_id}
        else
          {:ok, value}
        end

      _other ->
        {:error, :missing_user_id}
    end
  end

  defp normalize_string(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_string(value), do: value

  defp encode_jsonish(nil), do: nil
  defp encode_jsonish(value) when is_binary(value), do: value
  defp encode_jsonish(value), do: Jason.encode!(Redactor.redact(value))

  defp encode_event_payload(nil), do: nil
  defp encode_event_payload(value) when is_binary(value), do: value
  defp encode_event_payload(value), do: Jason.encode!(Redactor.redact(value))

  defp normalize_step_fields(attrs) do
    attrs
    |> update_if_present(:kind, &normalize_string/1)
    |> update_if_present(:status, &normalize_string/1)
    |> update_if_present(:stage, fn
      stage when is_atom(stage) -> Atom.to_string(stage)
      stage -> stage
    end)
  end

  defp update_if_present(attrs, key, fun) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> Map.put(attrs, key, fun.(value))
      :error -> attrs
    end
  end

  defp atomize_known(attrs) do
    Enum.reduce(attrs, %{}, fn {key, value}, acc ->
      Map.put(acc, normalize_key(key), value)
    end)
  end

  defp normalize_key(key) when is_binary(key) do
    if MapSet.member?(@known_keys, key), do: String.to_existing_atom(key), else: key
  end

  defp normalize_key(key), do: key
end
