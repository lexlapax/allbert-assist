defmodule AllbertAssist.Actions.Objectives.ListObjectives do
  @moduledoc "List durable objectives for one local user."

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :objectives_read,
    skill_backed?: false,
    confirmation: :not_required,
    retry_safety: :safe,
    name: "list_objectives",
    description: "List bounded objective summaries for a local user.",
    category: "objectives",
    tags: ["objectives", "read_only"],
    schema: [
      user_id: [type: :string, required: false],
      status: [type: :string, required: false],
      statuses: [type: {:list, :string}, required: false],
      active_app: [type: :string, required: false],
      limit: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      objectives: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Maps
  alias AllbertAssist.Objectives
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- user_id(params, context) do
      objectives =
        user_id
        |> Objectives.list_objectives(opts(params))
        |> Enum.map(&objective_map/1)

      {:ok,
       %{
         message: "Found #{length(objectives)} objective(s).",
         status: :completed,
         permission_decision: permission_decision,
         objectives: objectives,
         actions: [
           action(:completed, permission_decision, %{
             user_id: user_id,
             objective_count: length(objectives)
           })
         ]
       }}
    else
      {:allowed, false} ->
        {:ok, denied(permission_decision)}

      {:error, reason} ->
        {:ok, error(permission_decision, reason)}
    end
  end

  defp opts(params) do
    [
      status: field(params, :status),
      statuses: field(params, :statuses),
      active_app: field(params, :active_app),
      limit: field(params, :limit)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp objective_map(objective) do
    %{
      id: objective.id,
      user_id: objective.user_id,
      title: objective.title,
      objective: objective.objective,
      status: objective.status,
      active_app: objective.active_app,
      source_thread_id: objective.source_thread_id,
      current_step_id: objective.current_step_id,
      loop_count: objective.loop_count,
      updated_at: objective.updated_at
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp user_id(params, context) do
    case field(context, :user_id) || get_in_field(context, [:request, :user_id]) ||
           field(params, :user_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_user_id}
    end
  end

  defp denied(permission_decision) do
    %{
      message: permission_decision.reason,
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      objectives: [],
      actions: [action(:denied, permission_decision, %{error: :permission_denied})]
    }
  end

  defp error(permission_decision, reason) do
    %{
      message: "Unable to list objectives: #{inspect(reason)}",
      status: :error,
      error: reason,
      permission_decision: permission_decision,
      objectives: [],
      actions: [action(:error, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "list_objectives",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision
    }
    |> Map.merge(metadata)
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

  defp field(map, key) when is_map(map), do: Maps.field_truthy(map, key)

  defp field(_value, _key), do: nil
end
