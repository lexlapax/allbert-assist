defmodule AllbertAssist.Actions.Objectives.ShowObjective do
  @moduledoc "Show a durable objective with proposed steps and recent events."

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :objectives_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "show_objective",
    description: "Show objective details, steps, and recent events for a local user.",
    category: "objectives",
    tags: ["objectives", "read_only"],
    schema: [
      id: [type: :string, required: true],
      user_id: [type: :string, required: false],
      event_limit: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      objective: [type: :map, required: false],
      steps: [type: {:list, :map}, required: true],
      events: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Objectives
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Validation

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- user_id(params, context),
         {:ok, id} <- objective_id(params),
         {:ok, objective} <- Objectives.get_objective(user_id, id) do
      steps = objective.id |> Objectives.list_steps() |> Enum.map(&step_map/1)

      events =
        objective.id
        |> Objectives.list_events(limit: event_limit(params))
        |> Enum.map(&event_map/1)

      {:ok,
       %{
         message: "Objective #{objective.id}: #{objective.title}",
         status: :completed,
         permission_decision: permission_decision,
         objective: objective_map(objective),
         steps: steps,
         events: events,
         actions: [
           action(:completed, permission_decision, %{
             user_id: user_id,
             objective_id: objective.id,
             step_count: length(steps),
             event_count: length(events)
           })
         ]
       }}
    else
      {:allowed, false} ->
        {:ok, denied(permission_decision)}

      {:error, :not_found} ->
        {:ok, not_found(permission_decision)}

      {:error, reason} ->
        {:ok, error(permission_decision, reason)}
    end
  end

  defp objective_map(objective) do
    %{
      id: objective.id,
      user_id: objective.user_id,
      title: objective.title,
      objective: objective.objective,
      acceptance_criteria: decode(objective.acceptance_criteria),
      status: objective.status,
      active_app: objective.active_app,
      source_intent: objective.source_intent,
      source_thread_id: objective.source_thread_id,
      session_id: objective.session_id,
      current_step_id: objective.current_step_id,
      progress_summary: objective.progress_summary,
      last_observation_summary: objective.last_observation_summary,
      proposer_hint: decode(objective.proposer_hint),
      loop_count: objective.loop_count,
      inserted_at: objective.inserted_at,
      updated_at: objective.updated_at
    }
    |> drop_nil()
  end

  defp step_map(step) do
    %{
      id: step.id,
      objective_id: step.objective_id,
      parent_step_id: step.parent_step_id,
      kind: step.kind,
      status: step.status,
      stage: step.stage,
      provider: step.provider,
      candidate_action: step.candidate_action,
      delegate_agent_id: step.delegate_agent_id,
      action_params: decode(step.action_params),
      result_summary: step.result_summary,
      observation_summary: step.observation_summary,
      trace_id: step.trace_id,
      confirmation_id: step.confirmation_id,
      resource_access: decode(step.resource_access),
      inserted_at: step.inserted_at,
      updated_at: step.updated_at
    }
    |> drop_nil()
  end

  defp event_map(event) do
    %{
      id: event.id,
      objective_id: event.objective_id,
      step_id: event.step_id,
      kind: event.kind,
      summary: event.summary,
      payload: decode(event.payload),
      recorded_at: event.recorded_at
    }
    |> drop_nil()
  end

  defp user_id(params, context) do
    case field(params, :user_id) || field(context, :user_id) ||
           get_in_field(context, [:request, :user_id]) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_user_id}
    end
  end

  defp objective_id(params) do
    case field(params, :id) || field(params, :objective_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_objective_id}
    end
  end

  defp event_limit(params) do
    case field(params, :event_limit) do
      value when is_integer(value) -> Validation.clamp_limit(value, 1, 100)
      _other -> 25
    end
  end

  defp denied(permission_decision) do
    %{
      message: permission_decision.reason,
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      steps: [],
      events: [],
      actions: [action(:denied, permission_decision, %{error: :permission_denied})]
    }
  end

  defp not_found(permission_decision) do
    %{
      message: "Objective not found.",
      status: :not_found,
      error: :not_found,
      permission_decision: permission_decision,
      steps: [],
      events: [],
      actions: [action(:not_found, permission_decision, %{error: :not_found})]
    }
  end

  defp error(permission_decision, reason) do
    %{
      message: "Unable to show objective: #{inspect(reason)}",
      status: :error,
      error: reason,
      permission_decision: permission_decision,
      steps: [],
      events: [],
      actions: [action(:error, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "show_objective",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision
    }
    |> Map.merge(metadata)
  end

  defp decode(nil), do: nil

  defp decode(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _other -> value
    end
  end

  defp decode(value), do: value

  defp drop_nil(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp get_in_field(value, keys) do
    Enum.reduce_while(keys, value, fn key, acc ->
      case field(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp field(%_struct{} = struct, key), do: Map.get(struct, key)

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil
end
