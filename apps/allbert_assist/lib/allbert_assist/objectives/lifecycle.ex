defmodule AllbertAssist.Objectives.Lifecycle do
  @moduledoc """
  Transactional lifecycle facade used by background objective runs.

  Run processes call this public facade rather than private Jido command
  modules. Each lifecycle operation receives a fresh resolved-settings pin,
  so one operation is deterministic while operator changes become visible at
  the next boundary. Durable transitions and events remain authoritative.
  """

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Objectives.Runs.CancelToken
  alias AllbertAssist.Objectives.Steering
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.Signals

  @operations ~w[propose evaluate authorize execute observe advance]a
  @max_event_summary_chars 500
  @max_summary_chars 2_000

  @spec run(String.t(), keyword()) :: {:ok, Objective.t()} | {:blocked, term()} | {:error, term()}
  def run(child_id, opts \\ []) when is_binary(child_id) do
    adapter = Keyword.get(opts, :adapter, __MODULE__.DefaultAdapter)

    with {:ok, objective} <- begin_attempt(child_id),
         {:ok, state} <- run_operations(adapter, %{objective: objective}, opts) do
      complete(state)
    else
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

  defp begin_attempt(child_id) do
    with {:ok, objective} <- Objectives.get_objective(child_id) do
      attempt = (objective.run_attempt_count || 0) + 1

      persist_transition(
        objective,
        %{status: "running", run_attempt_count: attempt, review_reason: nil},
        "run_started",
        %{attempt: attempt}
      )
    end
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
            updated.progress_summary != objective.progress_summary

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
      {:ok, _step} -> {:ok, Map.drop(state, [:step, :response])}
      {:error, reason} -> {:error, reason}
    end
  end

  defp supersede_current_step(state), do: {:ok, Map.drop(state, [:step, :response])}

  defp pinned_operation(adapter, operation, current, opts) do
    Store.with_resolved_settings(fn -> adapter.operation(operation, current, opts) end)
  end

  defp continue_operations({:cancelled, next}, _adapter, _operation, _rest, _current, _opts),
    do: {:cancelled, next}

  defp continue_operations({:ok, next}, adapter, operation, rest, current, opts)
       when is_map(next) do
    case event(current.objective, "run_progress", %{operation: operation}) do
      {:ok, _event} ->
        Signals.emit_fanout(:run_progress, %{
          child_id: current.objective.id,
          parent_id: current.objective.parent_objective_id,
          operation: operation
        })

        run_operations(adapter, rest, next, opts)

      {:error, reason} ->
        {:error, reason, current}
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

  defp complete(%{objective: objective} = state) do
    summary =
      (get_in(state, [:response, :message]) || objective.progress_summary || "Completed.")
      |> bounded_summary()

    with {:ok, objective} <-
           persist_transition(
             objective,
             %{
               status: "completed",
               last_observation_summary: summary,
               completed_at: DateTime.utc_now()
             },
             "run_completed",
             %{summary: String.slice(summary, 0, @max_event_summary_chars)}
           ) do
      Signals.emit_fanout(:run_completed, %{
        child_id: objective.id,
        parent_id: objective.parent_objective_id,
        summary: summary
      })

      {:ok, objective}
    end
  end

  defp bounded_summary(summary) do
    summary = summary |> Redactor.redact(:signals) |> to_string()

    if String.length(summary) > @max_summary_chars do
      String.slice(summary, 0, @max_summary_chars - 1) <> "…"
    else
      summary
    end
  end

  defp block(%{objective: objective} = state, reason) do
    reason_text = inspect(reason, limit: 20, printable_limit: 300)

    with {:ok, objective} <-
           persist_transition(
             objective,
             %{status: "blocked", review_reason: reason_text},
             "run_blocked",
             %{reason: reason_text},
             fn -> park_step(state, reason) end
           ) do
      Signals.emit_fanout(:run_blocked, %{
        child_id: objective.id,
        parent_id: objective.parent_objective_id,
        reason: reason_text
      })

      {:blocked, reason}
    end
  end

  defp park_step(%{step: step}, {:needs_confirmation, confirmation_id}) do
    case Objectives.update_step(step, %{status: "blocked", confirmation_id: confirmation_id}) do
      {:ok, _step} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp park_step(_state, _reason), do: :ok

  defp cancel(%{objective: objective}) do
    with {:ok, objective} <-
           persist_transition(
             objective,
             %{
               status: "cancelled",
               review_reason: "cancelled",
               completed_at: DateTime.utc_now()
             },
             "run_cancelled",
             %{}
           ) do
      Signals.emit_fanout(:run_cancelled, %{
        child_id: objective.id,
        parent_id: objective.parent_objective_id
      })

      {:ok, objective}
    end
  end

  defp fail(%{objective: objective}, reason) do
    reason_text = inspect(reason, limit: 20, printable_limit: 300)

    with {:ok, objective} <-
           persist_transition(
             objective,
             %{
               status: "failed",
               review_reason: reason_text,
               completed_at: DateTime.utc_now()
             },
             "run_failed",
             %{reason: reason_text}
           ) do
      Signals.emit_fanout(:run_failed, %{
        child_id: objective.id,
        parent_id: objective.parent_objective_id,
        reason: reason_text
      })

      {:error, reason}
    end
  end

  defp event(objective, kind, payload) do
    Objectives.create_event(%{objective_id: objective.id, kind: kind, payload: payload})
  end

  defp persist_transition(objective, attrs, kind, payload, before \\ fn -> :ok end) do
    transaction = fn -> do_persist_transition(objective, attrs, kind, payload, before) end

    case Repo.transaction(transaction) do
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
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

    alias AllbertAssist.Actions.{Registry, Runner}
    alias AllbertAssist.Intent.{Decision, Engine}
    alias AllbertAssist.Objectives

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

    def operation(:evaluate, %{step: %{candidate_action: action}} = state, _opts)
        when is_binary(action) do
      case Registry.resolve(action) do
        {:ok, _module} -> {:ok, state}
        {:error, reason} -> {:error, reason, state}
      end
    end

    def operation(:evaluate, state, _opts), do: {:error, :missing_candidate_action, state}

    def operation(:authorize, state, _opts), do: {:ok, state}

    def operation(:execute, %{objective: objective, step: step} = state, opts) do
      params = decode_params(step.action_params)

      context = %{
        user_id: objective.user_id,
        active_app: objective.active_app,
        channel: objective.source_channel,
        surface: objective.source_surface,
        objective_id: objective.id,
        cancel_token: Keyword.get(opts, :cancel_token),
        registry: Keyword.get(opts, :registry, [])
      }

      case Runner.run(step.candidate_action, params, context) do
        {:ok, %{status: :needs_confirmation} = response} ->
          {:blocked, {:needs_confirmation, Map.get(response, :confirmation_id)},
           Map.put(state, :response, response)}

        {:ok, %{status: status} = response} when status in [:completed, :advisory] ->
          {:ok, Map.put(state, :response, response)}

        {:ok, response} ->
          {:error, {:action_not_completed, Map.get(response, :status)},
           Map.put(state, :response, response)}
      end
    end

    def operation(:observe, state, _opts), do: {:ok, state}
    def operation(:advance, state, _opts), do: {:ok, state}

    defp propose_step(objective, state) do
      request = %{
        text: objective.objective,
        user_id: objective.user_id,
        thread_id: objective.source_thread_id,
        session_id: objective.session_id,
        active_app: objective.active_app,
        channel: objective.source_channel
      }

      with {:ok, decision} <- Engine.decide(request),
           {:ok, action} <- selected_action(decision),
           {:ok, step} <-
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "action",
               status: "selected",
               stage: "propose_steps",
               candidate_action: action,
               action_params: Jason.encode!(action_params(action, decision, objective.objective)),
               resource_access:
                 decision
                 |> Decision.to_map()
                 |> Map.get(:resource_access, [])
                 |> Jason.encode!()
             }) do
        {:ok, Map.put(state, :step, step)}
      else
        {:error, reason} -> {:blocked, {:proposal_failed, reason}, state}
      end
    end

    defp selected_action(%{selected_action: action}) when is_binary(action) do
      case Registry.resolve(action) do
        {:ok, _capability} -> {:ok, action}
        {:error, _reason} -> {:ok, "direct_answer"}
      end
    end

    defp selected_action(_decision), do: {:ok, "direct_answer"}

    defp action_params(action, decision, text) do
      slots = get_in(decision.trace_metadata, [:extracted_slots]) || %{}

      case action do
        "direct_answer" -> Map.put_new(slots, :text, text)
        "external_network_request" -> Map.put_new(slots, :request, text)
        _other -> slots
      end
    end

    defp decode_params(nil), do: %{}

    defp decode_params(params) when is_binary(params) do
      case Jason.decode(params) do
        {:ok, %{} = decoded} -> decoded
        _ -> %{}
      end
    end
  end
end
