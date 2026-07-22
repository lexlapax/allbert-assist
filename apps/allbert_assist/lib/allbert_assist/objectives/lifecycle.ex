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
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.Signals

  @operations ~w[propose evaluate authorize execute observe advance]a

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
    Enum.reduce_while(@operations, {:ok, state}, fn operation, {:ok, current} ->
      adapter
      |> operation_result(operation, current, opts)
      |> reduce_operation_result(operation, current)
    end)
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

  defp pinned_operation(adapter, operation, current, opts) do
    Store.with_resolved_settings(fn -> adapter.operation(operation, current, opts) end)
  end

  defp reduce_operation_result({:cancelled, next}, _operation, _current),
    do: {:halt, {:cancelled, next}}

  defp reduce_operation_result({:ok, next}, operation, current) when is_map(next) do
    case event(current.objective, "run_progress", %{operation: operation}) do
      {:ok, _event} ->
        Signals.emit_fanout(:run_progress, %{
          child_id: current.objective.id,
          parent_id: current.objective.parent_objective_id,
          operation: operation
        })

        {:cont, {:ok, next}}

      {:error, reason} ->
        {:halt, {:error, reason, current}}
    end
  end

  defp reduce_operation_result({:blocked, reason, next}, _operation, _current),
    do: {:halt, {:blocked, reason, next}}

  defp reduce_operation_result({:error, reason, next}, _operation, _current),
    do: {:halt, {:error, reason, next}}

  defp reduce_operation_result({:error, reason}, _operation, current),
    do: {:halt, {:error, reason, current}}

  defp reduce_operation_result(other, operation, current),
    do: {:halt, {:error, {:invalid_lifecycle_result, operation, other}, current}}

  defp complete(%{objective: objective} = state) do
    summary = get_in(state, [:response, :message]) || objective.progress_summary || "Completed."

    with {:ok, objective} <-
           persist_transition(
             objective,
             %{
               status: "completed",
               last_observation_summary: summary,
               completed_at: DateTime.utc_now()
             },
             "run_completed",
             %{summary: summary}
           ) do
      Signals.emit_fanout(:run_completed, %{
        child_id: objective.id,
        parent_id: objective.parent_objective_id,
        summary: summary
      })

      {:ok, objective}
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
    @moduledoc false

    alias AllbertAssist.Actions.{Registry, Runner}
    alias AllbertAssist.Objectives

    def operation(:propose, %{objective: objective} = state, _opts) do
      case Objectives.list_steps(objective.id) do
        [] -> {:blocked, :awaiting_proposal, state}
        steps -> {:ok, Map.put(state, :step, List.last(steps))}
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

    defp decode_params(nil), do: %{}

    defp decode_params(params) when is_binary(params) do
      case Jason.decode(params) do
        {:ok, %{} = decoded} -> decoded
        _ -> %{}
      end
    end
  end
end
