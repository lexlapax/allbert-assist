defmodule AllbertAssist.Actions.Objectives.DelegateAgent do
  @moduledoc "Dispatch a bounded objective step to a registered delegate agent."

  use AllbertAssist.Action,
    permission: :objective_write,
    exposure: :internal,
    execution_mode: :objective_delegate,
    skill_backed?: false,
    confirmation: :not_required,
    name: "delegate_agent",
    description: "Dispatch a delegated objective step to a registered objective agent.",
    category: "objectives",
    tags: ["objectives", "delegate"],
    schema: [
      user_id: [type: :string, required: true],
      objective_id: [type: :string, required: true],
      step_id: [type: :string, required: true],
      delegate_agent_id: [type: :string, required: true],
      command: [type: :string, required: false],
      params: [type: :map, required: false],
      timeout_ms: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:objective_write, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, agent_id} <- agent_id(params),
         {:ok, command} <- command(params),
         {:ok, result} <-
           AgentRegistry.dispatch(agent_id, command, field(params, :params, %{}),
             timeout: delegate_timeout_ms(params)
           ) do
      {:ok,
       %{
         message: "Delegated objective step to #{agent_id}.",
         status: :completed,
         delegate_result: result,
         permission_decision: permission_decision,
         actions: [
           action(:completed, permission_decision, %{
             delegate_agent_id: agent_id,
             objective_id: field(params, :objective_id),
             step_id: field(params, :step_id),
             command: command
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

  defp agent_id(params) do
    case field(params, :delegate_agent_id) || field(params, :agent_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_delegate_agent_id}
    end
  end

  defp command(params) do
    value = field(params, :command, "execute")

    cond do
      is_atom(value) ->
        {:ok, value}

      value == "execute" ->
        {:ok, :execute}

      true ->
        {:error, :invalid_delegate_command}
    end
  end

  defp delegate_timeout_ms(params) do
    case field(params, :timeout_ms) do
      value when is_integer(value) and value > 0 -> min(value, 900_000)
      _other -> 180_000
    end
  end

  defp denied(permission_decision) do
    Response.denied(permission_decision.reason,
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, %{error: :permission_denied})]
    )
  end

  defp error(permission_decision, reason) do
    Response.error("Unable to delegate objective step: #{inspect(reason)}", reason,
      permission_decision: permission_decision,
      actions: [action(:error, permission_decision, %{error: reason})]
    )
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "delegate_agent",
      status: status,
      permission: :objective_write,
      permission_decision: permission_decision
    }
    |> Map.merge(metadata)
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default
end
