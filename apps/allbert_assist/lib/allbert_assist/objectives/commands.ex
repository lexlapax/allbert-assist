defmodule AllbertAssist.Objectives.Commands do
  @moduledoc false

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Security.Redactor
  alias AllbertAssist.Signals

  @doc false
  def finish(command, result, state, opts \\ []) do
    case result do
      {:ok, value} ->
        patch =
          state
          |> Map.merge(%{
            last_command: command,
            last_result: {:ok, value},
            last_error: nil
          })
          |> maybe_merge_projection(value)
          |> maybe_put(:last_summary, Keyword.get(opts, :summary))

        {:ok, patch, Keyword.get(opts, :directives, [])}

      {:error, reason} ->
        {:ok,
         %{
           last_command: command,
           last_result: {:error, reason},
           last_error: inspect(reason)
         }}
    end
  end

  @doc false
  def objective_attrs(params) do
    now_title = Map.get(params, :title) || Map.get(params, "title") || "Objective"

    %{
      user_id: Map.get(params, :user_id) || Map.get(params, "user_id"),
      source_thread_id: Map.get(params, :source_thread_id) || Map.get(params, "source_thread_id"),
      session_id: Map.get(params, :session_id) || Map.get(params, "session_id"),
      active_app: app_value(Map.get(params, :active_app) || Map.get(params, "active_app")),
      status: Map.get(params, :status) || Map.get(params, "status") || "open",
      title: now_title,
      objective: Map.get(params, :objective) || Map.get(params, "objective") || now_title,
      acceptance_criteria:
        Map.get(params, :acceptance_criteria) || Map.get(params, "acceptance_criteria"),
      constraints: Map.get(params, :constraints) || Map.get(params, "constraints"),
      source_intent: Map.get(params, :source_intent) || Map.get(params, "source_intent")
    }
  end

  @doc false
  def emit_objective(kind, %Objective{} = objective, metadata \\ %{}) do
    payload =
      metadata
      |> Map.put(:objective_id, objective.id)
      |> Map.put(:user_id, objective.user_id)
      |> Map.put(:source_thread_id, objective.source_thread_id)
      |> Map.put(:session_id, objective.session_id)
      |> Map.put(:active_app, objective.active_app)
      |> Map.put(:stage, Map.get(metadata, :stage))
      |> Map.put(:title, objective.title)
      |> Redactor.redact()

    with {:ok, signal} <- Signals.objective_lifecycle(kind, payload) do
      Signals.log(signal)
    end
  end

  defp maybe_merge_projection(state, %{objective: %Objective{} = objective, steps: steps}) do
    state
    |> update_nested(:active_objectives, objective.id, Objectives.objective_summary(objective))
    |> update_nested(:current_stage, objective.id, "propose_steps")
    |> update_nested(:loop_counts, objective.id, objective.loop_count || 0)
    |> maybe_put_proposer_hint(objective)
    |> maybe_put(:last_summary, %{objective_id: objective.id, proposed_steps: length(steps)})
  end

  defp maybe_merge_projection(state, %{objective: %Objective{} = objective}) do
    state
    |> update_nested(:active_objectives, objective.id, Objectives.objective_summary(objective))
    |> update_nested(:current_stage, objective.id, "frame_objective")
    |> update_nested(:loop_counts, objective.id, objective.loop_count || 0)
  end

  defp maybe_merge_projection(state, _value), do: state

  defp maybe_put_proposer_hint(state, %Objective{id: id, proposer_hint: nil}) do
    current = Map.get(state, :proposer_hints, %{})
    Map.put(state, :proposer_hints, Map.delete(current, id))
  end

  defp maybe_put_proposer_hint(state, %Objective{id: id, proposer_hint: hint}) do
    case hint && Jason.decode(hint) do
      {:ok, %{} = hint_map} ->
        current = Map.get(state, :proposer_hints, %{})

        case AllbertAssist.Objectives.Proposer.normalize_hint(hint_map) do
          {:ok, normalized_hint} ->
            Map.put(state, :proposer_hints, Map.put(current, id, normalized_hint))

          {:error, _reason} ->
            state
        end

      _other ->
        state
    end
  end

  defp update_nested(state, key, nested_key, value) do
    current = Map.get(state, key, %{})
    Map.put(state, key, Map.put(current, nested_key, value))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp app_value(nil), do: nil
  defp app_value(app) when is_atom(app), do: Atom.to_string(app)
  defp app_value(app), do: app
end

defmodule AllbertAssist.Objectives.Commands.FrameObjective do
  @moduledoc false

  use Jido.Action,
    name: "allbert_objectives_frame_objective",
    description: "Private objective framing command."

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Commands

  @impl true
  def run(params, context) do
    state = Map.get(context, :state, %{})
    attrs = Commands.objective_attrs(params)

    with {:ok, objective} <- Objectives.create_objective(attrs),
         {:ok, event} <-
           Objectives.create_event(%{
             objective_id: objective.id,
             kind: "created",
             summary: "Objective created.",
             payload: %{title: objective.title, status: objective.status}
           }) do
      Commands.emit_objective(:created, objective, %{stage: :frame_objective})
      Commands.finish(:frame_objective, {:ok, %{objective: objective, event: event}}, state)
    end
  end
end

defmodule AllbertAssist.Objectives.Commands.ProposeSteps do
  @moduledoc false

  use Jido.Action,
    name: "allbert_objectives_propose_steps",
    description: "Private objective step proposal command."

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Commands
  alias AllbertAssist.Objectives.Proposer
  alias AllbertAssist.Repo

  @impl true
  def run(params, context) do
    state = Map.get(context, :state, %{})

    with {:ok, objective_id} <- objective_id(params),
         {:ok, objective} <- Objectives.get_objective(objective_id),
         {:ok, intent_decision} <- intent_decision(params, objective),
         proposer_context <- proposer_context(params, context, objective, state) do
      case Proposer.propose(intent_decision, proposer_context) do
        {:ok, _steps, _continuation} = proposal ->
          with {:ok, result} <- persist_proposal(objective, proposal) do
            Commands.finish(:propose_steps, {:ok, result}, state)
          else
            {:error, reason} -> Commands.finish(:propose_steps, {:error, reason}, state)
          end

        {:no_steps, reason} ->
          record_no_steps(params, state, reason)

        {:error, reason} ->
          Commands.finish(:propose_steps, {:error, reason}, state)
      end
    else
      {:error, reason} ->
        Commands.finish(:propose_steps, {:error, reason}, state)
    end
  end

  defp persist_proposal(objective, {:ok, step_attrs, continuation}) do
    Repo.transaction(fn ->
      steps =
        Enum.map(step_attrs, fn attrs ->
          attrs =
            attrs
            |> Map.put(:objective_id, objective.id)
            |> Map.put_new(:status, "proposed")
            |> Map.put_new(:stage, "propose_steps")

          case Objectives.create_step(attrs) do
            {:ok, step} ->
              {:ok, _event} =
                Objectives.create_event(%{
                  objective_id: objective.id,
                  step_id: step.id,
                  kind: "step_proposed",
                  summary: "Proposed #{step.kind} objective step.",
                  payload: %{
                    candidate_action: step.candidate_action,
                    provider: step.provider,
                    continuation: continuation_summary(continuation)
                  }
                })

              step

            {:error, reason} ->
              Repo.rollback(reason)
          end
        end)

      objective =
        objective
        |> update_hint(continuation)
        |> case do
          {:ok, objective} -> objective
          {:error, reason} -> Repo.rollback(reason)
        end

      %{objective: objective, steps: steps, continuation: continuation_summary(continuation)}
    end)
  end

  defp update_hint(objective, :done),
    do: Objectives.update_objective(objective, %{proposer_hint: nil})

  defp update_hint(objective, {:more, hint}) do
    with {:ok, hint_map} <- Proposer.hint_to_map(hint) do
      Objectives.update_objective(objective, %{proposer_hint: hint_map})
    end
  end

  defp record_no_steps(params, state, reason) do
    case objective_id(params) do
      {:ok, objective_id} ->
        with {:ok, objective} <- Objectives.get_objective(objective_id),
             {:ok, event} <-
               Objectives.create_event(%{
                 objective_id: objective.id,
                 kind: "impasse",
                 summary: "No objective steps were proposed.",
                 payload: %{reason: reason, stage: :propose_steps}
               }) do
          Commands.finish(
            :propose_steps,
            {:ok, %{objective: objective, steps: [], event: event, no_steps_reason: reason}},
            state
          )
        else
          {:error, error} -> Commands.finish(:propose_steps, {:error, error}, state)
        end

      {:error, error} ->
        Commands.finish(:propose_steps, {:error, error}, state)
    end
  end

  defp objective_id(params) do
    case Map.get(params, :objective_id) || Map.get(params, "objective_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_objective_id}
    end
  end

  defp intent_decision(params, objective) do
    decision = Map.get(params, :intent_decision) || Map.get(params, "intent_decision")

    cond do
      is_map(decision) ->
        {:ok, decision}

      text = Map.get(params, :text) || Map.get(params, "text") ->
        {:ok, %{text: text, active_app: objective.active_app}}

      is_binary(objective.source_intent) ->
        {:ok, %{text: objective.source_intent, active_app: objective.active_app}}

      true ->
        {:ok, %{text: objective.objective, active_app: objective.active_app}}
    end
  end

  defp proposer_context(params, context, objective, state) do
    hint =
      Map.get(params, :proposer_hint) || Map.get(params, "proposer_hint") ||
        get_in(state, [:proposer_hints, objective.id])

    %{
      user_id: objective.user_id,
      thread_id: objective.source_thread_id,
      session_id: objective.session_id,
      active_app: objective.active_app,
      objective_id: objective.id,
      text: Map.get(params, :text) || Map.get(params, "text") || objective.source_intent,
      proposer_hint: hint
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.merge(Map.take(context, [:input_signal_id, :trace_id]))
  end

  defp continuation_summary(:done), do: %{status: :done}

  defp continuation_summary({:more, {app_id, state}}),
    do: %{status: :more, app_id: app_id, state: state}
end

defmodule AllbertAssist.Objectives.Commands.Noop do
  @moduledoc false

  use Jido.Action,
    name: "allbert_objectives_noop",
    description: "Private objective placeholder command."

  @impl true
  def run(params, context) do
    state = Map.get(context, :state, %{})
    command = Map.get(params, :command) || Map.get(params, "command") || :noop

    AllbertAssist.Objectives.Commands.finish(
      normalize_command(command),
      {:ok, %{status: :noop}},
      state
    )
  end

  defp normalize_command(command) when is_binary(command) do
    case command do
      "propose_steps" -> :propose_steps
      "evaluate_steps" -> :evaluate_steps
      "authorize_step" -> :authorize_step
      "execute_step" -> :execute_step
      "observe_step" -> :observe_step
      "advance_objective" -> :advance_objective
      "cancel_objective" -> :cancel_objective
      "continue_objective" -> :continue_objective
      "prune_stale" -> :prune_stale
      _other -> :noop
    end
  end

  defp normalize_command(command)
       when command in [
              :propose_steps,
              :evaluate_steps,
              :authorize_step,
              :execute_step,
              :observe_step,
              :advance_objective,
              :cancel_objective,
              :continue_objective,
              :prune_stale,
              :noop
            ],
       do: command

  defp normalize_command(_command), do: :noop
end
