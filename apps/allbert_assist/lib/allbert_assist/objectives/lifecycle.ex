defmodule AllbertAssist.Objectives.Lifecycle do
  @moduledoc """
  Transactional lifecycle facade used by background objective runs.

  Run processes call this public facade rather than private Jido command
  modules. Each lifecycle operation receives a fresh resolved-settings pin,
  so one operation is deterministic while operator changes become visible at
  the next boundary. Durable transitions and events remain authoritative.
  """

  require Logger

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Record, as: ConfirmationRecord
  alias AllbertAssist.Confirmations.ResumeParamsBinding
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.{Budget, TerminalTransitions}
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Objectives.ObservationSummary
  alias AllbertAssist.Objectives.Runs.CancelToken

  alias AllbertAssist.Objectives.Runs.Worker.{
    GroundedStepSpec,
    Grounding,
    QualityPolicy,
    QualityReceipt
  }

  alias AllbertAssist.Objectives.Steering
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.Signals

  @operations ~w[propose evaluate authorize execute observe advance]a
  @max_event_summary_chars 500
  @quality_protocol_upgrade_reason "quality_protocol_upgrade_required"

  @spec run(String.t(), keyword()) :: {:ok, Objective.t()} | {:blocked, term()} | {:error, term()}
  def run(child_id, opts \\ []) when is_binary(child_id) do
    adapter = Keyword.get(opts, :adapter, __MODULE__.DefaultAdapter)

    with {:ok, objective} <- begin_attempt(child_id),
         {:ok, state} <- run_operations(adapter, %{objective: objective}, opts) do
      complete_after_final_steering_boundary(adapter, state, opts)
    else
      {:terminal, objective} -> {:ok, objective}
      {:cancelled, state} -> cancel(state)
      {:blocked, reason, state} -> block(state, reason)
      {:error, reason, state} -> fail(state, reason)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec retry_safety(String.t()) :: :safe | :unsafe | :unknown
  def retry_safety(child_id) when is_binary(child_id) do
    case Objectives.list_steps(child_id) |> List.last() do
      %{candidate_action: action} when is_binary(action) ->
        case AllbertAssist.Actions.Registry.capability(action) do
          {:ok, capability} -> capability.retry_safety
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  end

  @doc "Fail one historical Budget v1 DirectAnswer child before recovery can execute it."
  @spec reconcile_quality_protocol_upgrade(Objective.t(), keyword()) ::
          {:ok, :current | {:failed, Objective.t()}} | {:error, term()}
  def reconcile_quality_protocol_upgrade(%Objective{} = objective, opts \\ [])
      when is_list(opts) do
    cond do
      quality_protocol_upgrade_failed?(objective) ->
        {:ok, {:failed, objective}}

      objective.status not in ~w[open running blocked] ->
        {:ok, :current}

      quality_protocol_upgrade_required?(objective, opts) ->
        transition_quality_protocol_upgrade(objective, opts)

      true ->
        {:ok, :current}
    end
  end

  defp begin_attempt(child_id) do
    with {:ok, objective} <- Objectives.get_objective(child_id) do
      case objective.status do
        status when status in ~w[open running] -> begin_new_attempt(objective)
        "blocked" -> begin_blocked_attempt(objective)
        status -> {:error, {:objective_not_runnable, status}}
      end
    end
  end

  defp begin_new_attempt(objective) do
    attempt = (objective.run_attempt_count || 0) + 1

    persist_transition(
      objective,
      %{status: "running", run_attempt_count: attempt, review_reason: nil},
      "run_started",
      %{attempt: attempt}
    )
    |> case do
      {:ok, objective} ->
        Signals.emit_fanout(:run_started, %{
          child_id: objective.id,
          parent_id: objective.parent_objective_id,
          attempt: objective.run_attempt_count
        })

        {:ok, objective}

      error ->
        error
    end
  end

  defp begin_blocked_attempt(objective) do
    case Steering.apply_pending(objective.id) do
      {:ok, %Objective{status: "running"} = steered} ->
        Signals.emit_fanout(:run_resumed, %{
          child_id: steered.id,
          parent_id: steered.parent_objective_id,
          reason: "operator_steering",
          attempt: steered.run_attempt_count
        })

        {:ok, steered}

      {:ok, %Objective{status: "blocked"} = blocked} ->
        begin_blocked_confirmation(blocked)

      {:ok, %Objective{status: status}} ->
        {:error, {:objective_not_runnable, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp begin_blocked_confirmation(objective) do
    case blocked_confirmation(objective) do
      {:ok, step, %{"status" => "approved"} = confirmation} ->
        resume_approved_confirmation(objective, step, confirmation)

      {:ok, step, %{"status" => "denied"} = confirmation} ->
        terminalize_denied_confirmation(objective, step, confirmation)

      {:ok, _step, confirmation} ->
        {:error, {:confirmation_not_resumable, effective_confirmation_status(confirmation)}}

      {:error, {:confirmation_not_found, _child_id}} ->
        {:error, {:objective_not_runnable, "blocked"}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_approved_confirmation(objective, step, confirmation) do
    result =
      persist_transition(
        objective,
        %{status: "running", review_reason: nil},
        "run_resumed",
        %{confirmation_id: confirmation["id"], attempt: objective.run_attempt_count}
      )

    publish_confirmation_resume(result, step, confirmation)
  end

  defp publish_confirmation_resume({:ok, resumed}, step, confirmation) do
    Signals.emit_fanout(:run_resumed, %{
      child_id: resumed.id,
      parent_id: resumed.parent_objective_id,
      confirmation_id: confirmation["id"],
      step_id: step.id,
      attempt: resumed.run_attempt_count
    })

    {:ok, resumed}
  end

  defp publish_confirmation_resume(error, _step, _confirmation), do: error

  defp terminalize_denied_confirmation(objective, step, confirmation) do
    case cancel_denied_confirmation(objective, step, confirmation) do
      {:ok, %{child: cancelled}} -> {:terminal, cancelled}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reconcile one blocked fan-out child after a durable confirmation decision."
  @spec reconcile_blocked(String.t()) ::
          {:ok, :runnable | :parked | {:terminalized, Objective.t()}} | {:error, term()}
  def reconcile_blocked(child_id) when is_binary(child_id) do
    with {:ok, %Objective{status: "blocked"} = objective} <- Objectives.get_objective(child_id) do
      case Steering.apply_pending(objective.id) do
        {:ok, %Objective{status: "running"}} ->
          {:ok, :runnable}

        {:ok, %Objective{status: "blocked"} = blocked} ->
          reconcile_blocked_confirmation(blocked)

        {:ok, %Objective{status: status}}
        when status in ~w[completed cancelled failed abandoned] ->
          {:ok, :parked}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, %Objective{status: status}} when status in ~w[completed cancelled failed abandoned] ->
        {:ok, :parked}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_blocked_confirmation(objective) do
    with {:ok, step, confirmation} <- blocked_confirmation(objective) do
      reconcile_confirmation_status(
        effective_confirmation_status(confirmation),
        objective,
        step,
        confirmation
      )
    else
      {:error, {:confirmation_not_found, _child_id}} -> {:ok, :parked}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_confirmation_status("approved", _objective, _step, _confirmation),
    do: {:ok, :runnable}

  defp reconcile_confirmation_status("denied", objective, step, confirmation) do
    case cancel_denied_confirmation(objective, step, confirmation) do
      {:ok, %{child: child}} -> {:ok, {:terminalized, child}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_confirmation_status(_status, _objective, _step, _confirmation),
    do: {:ok, :parked}

  defp quality_protocol_upgrade_failed?(%Objective{
         status: "failed",
         review_reason: @quality_protocol_upgrade_reason
       }),
       do: true

  defp quality_protocol_upgrade_failed?(%Objective{}), do: false

  defp quality_protocol_upgrade_required?(%Objective{} = objective, opts) do
    grounding = Grounding.resolve(objective)

    with %{"version" => 1} = budget <- grounding.fanout_budget,
         {:ok, ^budget} <- Budget.validate_snapshot(budget),
         true <-
           Keyword.get(opts, :force_quality_protocol_upgrade?, false) or
             direct_answer_upgrade_target?(objective, grounding) do
      true
    else
      _current_non_direct_or_invalid -> false
    end
  end

  defp direct_answer_upgrade_target?(objective, grounding) do
    case Store.with_resolved_settings(fn -> GroundedStepSpec.derive(objective, grounding) end) do
      {:ok, %{action_module: DirectAnswer}} -> true
      _non_direct_or_invalid -> false
    end
  end

  defp transition_quality_protocol_upgrade(objective, opts),
    do: transition_quality_protocol_upgrade(objective, opts, true)

  defp transition_quality_protocol_upgrade(objective, opts, retry_pending_steering?) do
    {attrs, transition_opts} = quality_protocol_upgrade_transition(objective, opts)

    objective
    |> TerminalTransitions.terminalize_child(
      attrs,
      "run_failed",
      %{reason: @quality_protocol_upgrade_reason},
      transition_opts
    )
    |> resolve_quality_protocol_upgrade_transition(objective, opts, retry_pending_steering?)
  end

  defp quality_protocol_upgrade_transition(objective, opts) do
    step =
      objective.id
      |> Objectives.list_steps()
      |> Enum.reject(&(&1.status in ~w[completed failed cancelled skipped]))
      |> List.last()

    attrs = %{
      status: "failed",
      review_reason: @quality_protocol_upgrade_reason,
      completed_at: DateTime.utc_now()
    }

    attrs = if step, do: Map.put(attrs, :current_step_id, step.id), else: attrs

    transaction_hook = quality_protocol_upgrade_hook(step, Keyword.get(opts, :transaction_hook))

    transition_opts =
      opts
      |> Keyword.take([:signal])
      |> Keyword.put_new(
        :signal,
        {:run_failed, %{reason: @quality_protocol_upgrade_reason}}
      )
      |> Keyword.put(:transaction_hook, transaction_hook)

    {attrs, transition_opts}
  end

  defp quality_protocol_upgrade_hook(step, outer_hook) do
    fn child ->
      with :ok <- finalize_quality_protocol_upgrade_step(step) do
        run_quality_protocol_upgrade_hook(outer_hook, child)
      end
    end
  end

  defp run_quality_protocol_upgrade_hook(hook, child) when is_function(hook, 1), do: hook.(child)
  defp run_quality_protocol_upgrade_hook(_hook, _child), do: :ok

  defp resolve_quality_protocol_upgrade_transition(
         {:ok, %{child: failed}},
         _objective,
         _opts,
         _retry_pending_steering?
       ),
       do: {:ok, {:failed, failed}}

  defp resolve_quality_protocol_upgrade_transition(
         {:error, {:objective_not_terminalizable, "failed"}},
         objective,
         _opts,
         _retry_pending_steering?
       ),
       do: resolve_existing_quality_protocol_upgrade(objective.id)

  defp resolve_quality_protocol_upgrade_transition(
         {:error, :pending_steering_directive},
         objective,
         opts,
         true
       ) do
    with {:ok, steered} <- Steering.apply_pending(objective.id) do
      transition_quality_protocol_upgrade(steered, opts, false)
    end
  end

  defp resolve_quality_protocol_upgrade_transition(
         {:error, reason},
         _objective,
         _opts,
         _retry_pending_steering?
       ),
       do: {:error, reason}

  defp resolve_existing_quality_protocol_upgrade(objective_id) do
    case Objectives.get_objective(objective_id) do
      {:ok, %Objective{} = current} -> resolve_existing_quality_protocol_upgrade_state(current)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_existing_quality_protocol_upgrade_state(current) do
    if quality_protocol_upgrade_failed?(current),
      do: {:ok, {:failed, current}},
      else: {:error, {:objective_not_terminalizable, current.status}}
  end

  defp finalize_quality_protocol_upgrade_step(nil), do: :ok

  defp finalize_quality_protocol_upgrade_step(step) do
    case Objectives.transition_step(step, "failed", %{
           result_summary: @quality_protocol_upgrade_reason
         }) do
      {:ok, _failed} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp blocked_confirmation(objective) do
    step =
      objective.id
      |> Objectives.list_steps()
      |> Enum.find(&(&1.id == objective.current_step_id))

    case step do
      %{status: "blocked", confirmation_id: id} = step when is_binary(id) and id != "" ->
        case Confirmations.read(id) do
          {:ok, confirmation} -> {:ok, step, confirmation}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, {:confirmation_not_found, objective.id}}
    end
  end

  defp effective_confirmation_status(%{"status" => "pending"} = confirmation) do
    if ConfirmationRecord.expired?(confirmation, DateTime.utc_now()),
      do: "expired",
      else: "pending"
  end

  defp effective_confirmation_status(confirmation), do: Map.get(confirmation, "status")

  defp cancel_denied_confirmation(objective, step, confirmation) do
    reason =
      get_in(confirmation, ["operator_resolution", "resolution_reason"]) ||
        "confirmation_denied"

    attrs = %{
      status: "cancelled",
      review_reason: "confirmation_denied: #{String.slice(to_string(reason), 0, 210)}",
      completed_at: DateTime.utc_now()
    }

    with {:ok, attrs} <- terminal_attrs(attrs, objective, step),
         result <-
           TerminalTransitions.terminalize_child(
             objective,
             attrs,
             "run_cancelled",
             %{confirmation_id: confirmation["id"], reason: "confirmation_denied"},
             transaction_hook: fn _child -> finalize_step(step, "cancelled", reason) end,
             signal:
               {:run_cancelled,
                %{confirmation_id: confirmation["id"], reason: "confirmation_denied"}}
           ) do
      case result do
        {:ok, %{child: child}} = result ->
          annotate_confirmation_record(confirmation, child, step, "cancelled", reason)
          result

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc "Repair terminal fan-out confirmation resolution after a process restart."
  @spec reconcile_confirmation_outcomes(String.t()) :: :ok | {:error, term()}
  def reconcile_confirmation_outcomes(parent_id) when is_binary(parent_id) do
    parent_id
    |> Fanout.children()
    |> Enum.filter(&(&1.status in ~w[completed cancelled failed abandoned]))
    |> Enum.reduce_while(:ok, fn child, :ok ->
      step = Enum.find(Objectives.list_steps(child.id), &(&1.id == child.current_step_id))

      case step do
        %{confirmation_id: id} when is_binary(id) and id != "" ->
          reconcile_confirmation_record(child, step, id)

        _other ->
          {:cont, :ok}
      end
    end)
  end

  defp reconcile_confirmation_record(child, step, confirmation_id) do
    case Confirmations.read(confirmation_id) do
      {:ok, %{"status" => status} = confirmation} when status in ~w[approved denied] ->
        summary = child.last_observation_summary || child.review_reason || "#{child.status}."

        case annotate_confirmation_record(confirmation, child, step, child.status, summary) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {child.id, reason}}}
        end

      _other ->
        {:cont, :ok}
    end
  end

  defp run_operations(adapter, state, opts) do
    run_operations(adapter, @operations, state, opts)
  end

  defp run_operations(_adapter, [], state, _opts), do: {:ok, state}

  defp run_operations(adapter, [operation | rest], state, opts) do
    {current, steered?} = reconcile_steering(state)

    case prepare_steered_operation(operation, current, steered?) do
      {:continue, current} ->
        adapter
        |> operation_result(operation, current, opts)
        |> continue_operations(adapter, operation, rest, current, opts)

      {:restart, current} ->
        run_operations(adapter, @operations, current, opts)

      {:blocked, reason, current} ->
        {:blocked, reason, current}

      {:error, reason, current} ->
        {:error, reason, current}
    end
  end

  defp operation_result(adapter, operation, current, opts) do
    case Keyword.get(opts, :cancel_token) do
      %CancelToken{} = token ->
        if CancelToken.cancelled?(token) do
          {:cancelled, current}
        else
          pinned_operation(adapter, operation, current, opts)
        end

      nil ->
        pinned_operation(adapter, operation, current, opts)
    end
  end

  defp reconcile_steering(%{objective: objective} = state) do
    case Steering.apply_pending(objective.id) do
      {:ok, updated} ->
        steered? =
          updated.objective != objective.objective or updated.title != objective.title or
            updated.progress_summary != objective.progress_summary or
            updated.updated_at != objective.updated_at

        {%{state | objective: updated}, steered?}

      {:error, _reason} ->
        {state, false}
    end
  end

  defp prepare_steered_operation(_operation, state, false), do: {:continue, state}

  defp prepare_steered_operation(operation, state, true) do
    if Map.has_key?(state, :response) and retry_safety(state.objective.id) != :safe do
      {:blocked, :steer_after_effect_requires_review, state}
    else
      case supersede_current_step(state) do
        {:ok, current} when operation == :propose -> {:continue, current}
        {:ok, current} -> {:restart, current}
        {:error, reason} -> {:error, reason, state}
      end
    end
  end

  defp supersede_current_step(%{step: step} = state) do
    result =
      if step.status in ~w[completed skipped cancelled failed] do
        {:ok, step}
      else
        Objectives.update_step(step, %{status: "cancelled"})
      end

    case result do
      {:ok, _step} ->
        {:ok,
         Map.drop(state, [
           :step,
           :response,
           :worker_adapter,
           :quality_receipt,
           :quality_receipt_digest
         ])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp supersede_current_step(state) do
    {:ok,
     Map.drop(state, [
       :step,
       :response,
       :worker_adapter,
       :quality_receipt,
       :quality_receipt_digest
     ])}
  end

  defp pinned_operation(adapter, operation, current, opts) do
    if function_exported?(adapter, :owns_settings_pin?, 1) and
         adapter.owns_settings_pin?(operation) do
      adapter.operation(operation, current, opts)
    else
      Store.with_resolved_settings(fn -> adapter.operation(operation, current, opts) end)
    end
  end

  defp continue_operations({:cancelled, next}, _adapter, _operation, _rest, _current, _opts),
    do: {:cancelled, next}

  defp continue_operations({:ok, next}, adapter, operation, rest, current, opts)
       when is_map(next) do
    case verify_operation_result(operation, next) do
      {:ok, verified} ->
        case event(current.objective, "run_progress", %{operation: operation}) do
          {:ok, _event} ->
            Signals.emit_fanout(:run_progress, %{
              child_id: current.objective.id,
              parent_id: current.objective.parent_objective_id,
              operation: operation
            })

            run_operations(adapter, rest, verified, opts)

          {:error, reason} ->
            {:error, reason, current}
        end

      {:error, reason} ->
        {:error, reason, next}
    end
  end

  defp continue_operations(
         {:blocked, reason, next},
         _adapter,
         _operation,
         _rest,
         _current,
         _opts
       ),
       do: {:blocked, reason, next}

  defp continue_operations(
         {:error, reason, next},
         _adapter,
         _operation,
         _rest,
         _current,
         _opts
       ),
       do: {:error, reason, next}

  defp continue_operations(
         {:error, reason},
         _adapter,
         _operation,
         _rest,
         current,
         _opts
       ),
       do: {:error, reason, current}

  defp continue_operations(other, _adapter, operation, _rest, current, _opts),
    do: {:error, {:invalid_lifecycle_result, operation, other}, current}

  defp verify_operation_result(:observe, state), do: verify_quality_completion(state)
  defp verify_operation_result(_operation, state), do: {:ok, state}

  defp verify_quality_completion(%{objective: objective} = state) do
    summary =
      (get_in(state, [:response, :message]) || objective.progress_summary || "Completed.")
      |> bounded_summary()

    case quality_task_binding(state) do
      {:ok, task_digests} ->
        verify_required_quality_receipt(state, summary, task_digests)

      :not_required ->
        if is_nil(Map.get(state, :quality_receipt)) do
          {:ok, Map.delete(state, :quality_receipt_digest)}
        else
          {:error, :unexpected_fanout_worker_quality_receipt}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp quality_task_binding(%{objective: objective, step: %{candidate_action: action}})
       when is_binary(action) do
    grounding = Grounding.resolve(objective)

    case Registry.resolve(action) do
      {:ok, DirectAnswer} -> quality_task_binding_from_grounding(grounding)
      {:ok, _non_direct_answer} -> :not_required
      {:error, reason} -> {:error, {:invalid_fanout_worker_quality_action, reason}}
    end
  end

  defp quality_task_binding(_state), do: :not_required

  defp quality_task_binding_from_grounding(%{source: source} = grounding)
       when source in [:conversation_manager, :counted_protocol, :operator_steered] do
    with {:ok, contract} <- QualityPolicy.build(grounding),
         {:ok, digests} <- QualityPolicy.receipt_task_digests(contract) do
      {:ok, digests}
    else
      {:error, reason} -> {:error, {:invalid_fanout_worker_quality_task, reason}}
    end
  end

  defp quality_task_binding_from_grounding(%{source: :untrusted}),
    do: {:error, :untrusted_fanout_worker_quality_task}

  defp quality_task_binding_from_grounding(_legacy_or_ordinary), do: :not_required

  defp verify_required_quality_receipt(state, summary, task_digests) do
    case Map.fetch(state, :quality_receipt) do
      {:ok, receipt} when is_map(receipt) ->
        binding = %{
          objective_id: state.objective.id,
          step_id: state.step.id,
          task_contract_sha256: task_digests["2"],
          task_contract_sha256_by_rule_catalog_version: task_digests,
          final_answer: summary
        }

        with :ok <- QualityReceipt.validate_current(receipt, binding),
             {:ok, digest} <- QualityReceipt.digest(receipt) do
          {:ok, Map.put(state, :quality_receipt_digest, digest)}
        else
          {:error, reason} ->
            {:error, {:invalid_fanout_worker_quality_receipt, reason}}
        end

      _missing ->
        {:error, :missing_fanout_worker_quality_receipt}
    end
  end

  defp complete(state) do
    case verify_quality_completion(state) do
      {:ok, verified} -> do_complete(verified)
      {:error, reason} -> fail(state, reason)
    end
  end

  defp do_complete(%{objective: objective} = state) do
    summary =
      (get_in(state, [:response, :message]) || objective.progress_summary || "Completed.")
      |> bounded_summary()

    attrs = %{
      status: "completed",
      last_observation_summary: summary,
      completed_at: DateTime.utc_now()
    }

    with {:ok, attrs} <- terminal_attrs(attrs, objective, Map.get(state, :step)),
         {:ok, %{child: completed}} <-
           TerminalTransitions.terminalize_child(
             objective,
             attrs,
             "run_completed",
             completion_event_payload(state, summary),
             transaction_hook: fn _child -> finalize_state_step(state, "completed", summary) end,
             signal: {:run_completed, %{summary: summary}}
           ) do
      annotate_confirmation_outcome(state, "completed", summary)
      {:ok, completed}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp completion_event_payload(
         %{quality_receipt: receipt, quality_receipt_digest: digest},
         _summary
       )
       when is_map(receipt) and is_binary(digest),
       do: %{quality_receipt: receipt}

  defp completion_event_payload(_state, summary),
    do: %{summary: String.slice(summary, 0, @max_event_summary_chars)}

  defp complete_after_final_steering_boundary(adapter, state, opts) do
    {current, steered?} = reconcile_steering(state)

    if steered? do
      adapter
      |> run_operations(current, opts)
      |> finish_rerun(adapter, opts)
    else
      case complete(current) do
        {:error, :pending_steering_directive} ->
          complete_after_final_steering_boundary(adapter, current, opts)

        result ->
          result
      end
    end
  end

  defp finish_rerun({:ok, state}, adapter, opts),
    do: complete_after_final_steering_boundary(adapter, state, opts)

  defp finish_rerun({:cancelled, state}, _adapter, _opts), do: cancel(state)
  defp finish_rerun({:blocked, reason, state}, _adapter, _opts), do: block(state, reason)
  defp finish_rerun({:error, reason, state}, _adapter, _opts), do: fail(state, reason)

  defp bounded_summary(summary), do: ObservationSummary.normalize(summary)

  defp block(%{objective: objective} = state, reason) do
    reason_text = inspect(reason, limit: 20, printable_limit: 300)
    current_step_id = state |> Map.get(:step, %{}) |> Map.get(:id)

    with {:ok, parking_attrs} <- confirmation_parking_attrs(state, reason),
         {:ok, objective} <-
           persist_transition(
             objective,
             %{
               status: "blocked",
               review_reason: reason_text,
               current_step_id: current_step_id
             },
             "run_blocked",
             %{reason: reason_text},
             fn -> park_step(state, reason, parking_attrs) end
           ) do
      Signals.emit_fanout(:run_blocked, %{
        child_id: objective.id,
        parent_id: objective.parent_objective_id,
        reason: reason_text
      })

      {:blocked, reason}
    end
  end

  defp park_step(%{step: step}, {:needs_confirmation, _confirmation_id}, attrs)
       when is_map(attrs) do
    case Objectives.update_step(step, attrs) do
      {:ok, _step} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp park_step(_state, _reason, nil), do: :ok

  defp confirmation_parking_attrs(
         %{objective: objective, step: step},
         {:needs_confirmation, confirmation_id}
       ) do
    grounded_confirmation_parking_attrs(objective, step, confirmation_id)
  end

  defp confirmation_parking_attrs(_state, _reason), do: {:ok, nil}

  defp grounded_confirmation_parking_attrs(objective, step, confirmation_id) do
    grounding = Grounding.resolve(objective)

    if grounding.source in [:ordinary, :legacy_ordinary] do
      {:ok, %{status: "blocked", confirmation_id: confirmation_id}}
    else
      with {:ok, confirmation} <- Confirmations.read(confirmation_id),
           {:ok, %{child: %{id: child_id}, step: %{id: step_id}}} <-
             Objectives.fanout_confirmation_target(confirmation),
           true <- child_id == objective.id and step_id == step.id,
           %{} = resume_params <- Map.get(confirmation, "resume_params_ref"),
           {:ok, digest} <- ResumeParamsBinding.digest(resume_params) do
        {:ok,
         %{
           status: "blocked",
           confirmation_id: confirmation_id,
           confirmation_resume_params_sha256: digest
         }}
      else
        false -> {:error, :confirmation_target_mismatch}
        nil -> {:error, :invalid_confirmation_resume_params}
        {:error, reason} -> {:error, reason}
        _invalid -> {:error, :confirmation_target_mismatch}
      end
    end
  end

  defp cancel(%{objective: objective} = state) do
    attrs = %{
      status: "cancelled",
      review_reason: "cancelled",
      completed_at: DateTime.utc_now()
    }

    with {:ok, attrs} <- terminal_attrs(attrs, objective, Map.get(state, :step)),
         {:ok, %{child: cancelled}} <-
           TerminalTransitions.terminalize_child(
             objective,
             attrs,
             "run_cancelled",
             %{},
             transaction_hook: fn _child ->
               finalize_state_step(state, "cancelled", "cancelled")
             end,
             signal: {:run_cancelled, %{}}
           ) do
      annotate_confirmation_outcome(state, "cancelled", "cancelled")
      {:ok, cancelled}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp fail(%{objective: objective} = state, reason) do
    reason_text = inspect(reason, limit: 20, printable_limit: 300)

    attrs = %{
      status: "failed",
      review_reason: reason_text,
      completed_at: DateTime.utc_now()
    }

    with {:ok, attrs} <- terminal_attrs(attrs, objective, Map.get(state, :step)),
         {:ok, %{child: _failed}} <-
           TerminalTransitions.terminalize_child(
             objective,
             attrs,
             "run_failed",
             %{reason: reason_text},
             transaction_hook: fn _child -> finalize_state_step(state, "failed", reason_text) end,
             signal: {:run_failed, %{reason: reason_text}}
           ) do
      annotate_confirmation_outcome(state, "failed", reason_text)
      {:error, reason}
    else
      {:error, transition_reason} -> {:error, transition_reason}
    end
  end

  defp annotate_confirmation_outcome(
         %{objective: objective, step: %{confirmation_id: id} = step},
         status,
         summary
       )
       when is_binary(id) and id != "" do
    case Confirmations.read(id) do
      {:ok, confirmation} ->
        annotate_confirmation_record(confirmation, objective, step, status, summary)

      {:error, reason} ->
        log_confirmation_annotation_error(id, status, reason)
    end
  end

  defp annotate_confirmation_outcome(_state, _status, _summary), do: :ok

  defp annotate_confirmation_record(confirmation, objective, step, status, summary) do
    id = confirmation["id"]
    resumed? = confirmation["status"] == "approved"
    resolution = Map.get(confirmation, "operator_resolution", %{}) || %{}

    if resolution["target_status"] == status and
         resolution["target_resumed?"] == resumed? do
      :ok
    else
      case Confirmations.annotate_resolution(id, %{
             target_resumed?: resumed?,
             target_status: status,
             target_result: %{
               objective_id: objective.id,
               step_id: step.id,
               status: status,
               summary: bounded_summary(summary)
             }
           }) do
        {:ok, _record} ->
          :ok

        {:error, reason} ->
          log_confirmation_annotation_error(id, status, reason)
      end
    end
  end

  defp log_confirmation_annotation_error(id, status, reason) do
    Logger.warning(
      "could not annotate terminal confirmation outcome confirmation_id=#{id} status=#{status} reason=#{inspect(reason)}"
    )

    {:error, reason}
  end

  defp finalize_state_step(%{step: step}, status, summary),
    do: finalize_step(step, status, summary)

  defp finalize_state_step(_state, _status, _summary), do: {:ok, %{}}

  defp terminal_attrs(
         attrs,
         %Objective{id: objective_id},
         %{id: step_id, objective_id: objective_id}
       )
       when is_binary(step_id),
       do: {:ok, Map.put(attrs, :current_step_id, step_id)}

  defp terminal_attrs(
         _attrs,
         %Objective{id: objective_id},
         %{id: step_id, objective_id: step_objective_id}
       )
       when is_binary(step_id) do
    {:error, {:terminal_step_objective_mismatch, step_id, step_objective_id, objective_id}}
  end

  defp terminal_attrs(attrs, %Objective{}, nil), do: {:ok, attrs}

  defp terminal_attrs(_attrs, %Objective{}, _invalid_step),
    do: {:error, :invalid_terminal_step_binding}

  defp finalize_step(step, status, summary) do
    case step.status do
      ^status ->
        {:ok, %{step_id: step.id, step_status: step.status}}

      terminal when terminal in ~w[completed failed cancelled skipped] ->
        {:error, {:incompatible_terminal_step_status, step.id, terminal, status}}

      _active ->
        case Objectives.transition_step(step, status, %{
               result_summary: String.slice(to_string(summary), 0, 2_000)
             }) do
          {:ok, updated} -> {:ok, %{step_id: updated.id, step_status: updated.status}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp event(objective, kind, payload) do
    Objectives.create_event(%{objective_id: objective.id, kind: kind, payload: payload})
  end

  defp persist_transition(objective, attrs, kind, payload, before \\ fn -> :ok end) do
    if objective.fanout_role == "child" do
      TerminalTransitions.transition_active_child(objective, attrs, kind, payload,
        transaction_hook: fn _updated -> before.() end
      )
    else
      transaction = fn -> do_persist_transition(objective, attrs, kind, payload, before) end

      case Repo.transaction(transaction) do
        {:ok, updated} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp do_persist_transition(objective, attrs, kind, payload, before) do
    with :ok <- before.(),
         {:ok, updated} <- Objectives.update_objective(objective, attrs),
         {:ok, _event} <- event(updated, kind, payload) do
      updated
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defmodule DefaultAdapter do
    @moduledoc """
    Uses the shared intent engine to propose one inert registered-action step,
    then executes it through the normal Registry/Runner authority boundary.
    """

    alias AllbertAssist.Actions.Registry
    alias AllbertAssist.Objectives
    alias AllbertAssist.Objectives.Runs.Worker
    alias AllbertAssist.Objectives.Runs.Worker.{GroundedStepSpec, Grounding}

    @doc false
    def owns_settings_pin?(:execute), do: true
    def owns_settings_pin?(_operation), do: false

    def operation(:propose, %{objective: objective} = state, _opts) do
      active_step =
        objective.id
        |> Objectives.list_steps()
        |> Enum.reject(&(&1.status in ~w[completed skipped cancelled failed]))
        |> List.last()

      case active_step do
        nil -> propose_step(objective, state)
        step -> {:ok, Map.put(state, :step, step)}
      end
    end

    def operation(
          :evaluate,
          %{objective: objective, step: %{candidate_action: action}} = state,
          _opts
        )
        when is_binary(action) do
      grounding = Grounding.resolve(objective)

      with :ok <- GroundedStepSpec.validate(objective, state.step, grounding),
           {:ok, action_module} <- Registry.resolve(action),
           :ok <- Grounding.authorize_action(grounding, action_module) do
        {:ok, state}
      else
        {:error, reason} -> {:error, reason, state}
      end
    end

    def operation(:evaluate, state, _opts), do: {:error, :missing_candidate_action, state}

    def operation(:authorize, state, _opts), do: {:ok, state}

    def operation(:execute, %{objective: objective, step: step} = state, opts) do
      grounding = Grounding.resolve(objective)

      context =
        %{
          user_id: objective.user_id,
          operator_id: objective.user_id,
          actor: objective.user_id,
          active_app: objective.active_app,
          channel: objective.source_channel,
          surface: objective.source_surface,
          thread_id: objective.source_thread_id,
          session_id: objective.session_id,
          objective_id: objective.id,
          step_id: step.id,
          parent_objective_id: objective.parent_objective_id,
          objective_title: objective.title,
          objective_status: objective.status,
          objective_run_attempt: objective.run_attempt_count,
          fanout_budget: grounding.fanout_budget,
          fanout_deadline_unix_ms: grounding.fanout_deadline_unix_ms,
          fanout_grounding: grounding,
          cancel_token: Keyword.get(opts, :cancel_token),
          registry: Keyword.get(opts, :registry, [])
        }

      with :ok <-
             Store.with_resolved_settings(fn ->
               GroundedStepSpec.validate(objective, step, grounding)
             end),
           {:ok, params, context} <- execution_request(objective, step, context, grounding) do
        case Worker.run(step.candidate_action, params, context, opts) do
          {:ok, %{adapter: adapter, response: response} = result} ->
            state = put_quality_receipt(state, result.quality_receipt)
            worker_response(response, adapter, state)

          {:error, reason} ->
            {:error, reason, state}
        end
      else
        {:error, reason} -> {:error, reason, state}
      end
    end

    def operation(:observe, state, _opts), do: {:ok, state}
    def operation(:advance, state, _opts), do: {:ok, state}

    defp put_quality_receipt(state, receipt) when is_map(receipt),
      do: Map.put(state, :quality_receipt, receipt)

    defp put_quality_receipt(state, nil), do: Map.delete(state, :quality_receipt)

    defp worker_response(%{status: :needs_confirmation} = response, adapter, state) do
      {:blocked, {:needs_confirmation, Map.get(response, :confirmation_id)},
       state |> Map.put(:response, response) |> Map.put(:worker_adapter, adapter)}
    end

    defp worker_response(%{status: status} = response, adapter, state)
         when status in [:completed, :advisory] do
      {:ok, state |> Map.put(:response, response) |> Map.put(:worker_adapter, adapter)}
    end

    defp worker_response(response, adapter, state) do
      next = state |> Map.put(:response, response) |> Map.put(:worker_adapter, adapter)
      {:error, {:action_not_completed, Map.get(response, :status)}, next}
    end

    defp propose_step(objective, state) do
      grounding = Grounding.resolve(objective)

      with {:ok, spec} <- GroundedStepSpec.derive(objective, grounding),
           {:ok, step} <-
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "action",
               status: "selected",
               stage: "propose_steps",
               candidate_action: spec.action,
               action_params: Jason.encode!(spec.params),
               resource_access: Jason.encode!(spec.resource_access)
             }) do
        {:ok, Map.put(state, :step, step)}
      else
        {:error, reason} -> {:blocked, {:proposal_failed, reason}, state}
      end
    end

    defp decode_params(nil), do: %{}

    defp decode_params(params) when is_binary(params) do
      case Jason.decode(params) do
        {:ok, %{} = decoded} -> decoded
        _ -> %{}
      end
    end

    defp execution_request(_objective, %{confirmation_id: nil} = step, context, _grounding),
      do: {:ok, decode_params(step.action_params), context}

    defp execution_request(objective, %{confirmation_id: id} = step, context, grounding)
         when is_binary(id) and id != "" do
      case AllbertAssist.Confirmations.read(id) do
        {:ok, %{"status" => "approved"} = record} ->
          with target_action when target_action == step.candidate_action <-
                 get_in(record, ["target_action", "name"]),
               {:ok, %{child: %{id: child_id}, step: %{id: step_id}}} <-
                 Objectives.fanout_confirmation_target(record),
               true <- child_id == objective.id and step_id == step.id,
               %{} = params <- Map.get(record, "resume_params_ref", %{}),
               :ok <- GroundedStepSpec.validate_resume_params(step, params, grounding) do
            confirmation = %{
              id: id,
              approved?: true,
              status: "approved",
              origin: Map.get(record, "origin", %{}),
              params_summary: Map.get(record, "params_summary", %{})
            }

            {:ok, params, Map.put(context, :confirmation, confirmation)}
          else
            {:error, reason} -> {:error, reason}
            _mismatch -> {:error, :confirmation_target_mismatch}
          end

        {:ok, %{"status" => status}} ->
          {:error, {:confirmation_not_approved, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp execution_request(_objective, step, context, _grounding),
      do: {:ok, decode_params(step.action_params), context}
  end
end
