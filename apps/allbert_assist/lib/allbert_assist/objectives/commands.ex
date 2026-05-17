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

  defp maybe_merge_projection(state, %{objective: %Objective{} = objective}) do
    state
    |> update_nested(:active_objectives, objective.id, Objectives.objective_summary(objective))
    |> update_nested(:current_stage, objective.id, "frame_objective")
    |> update_nested(:loop_counts, objective.id, objective.loop_count || 0)
  end

  defp maybe_merge_projection(state, _value), do: state

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
