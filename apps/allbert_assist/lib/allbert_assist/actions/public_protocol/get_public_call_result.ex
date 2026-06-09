defmodule AllbertAssist.Actions.PublicProtocol.GetPublicCallResult do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :read_only,
    skill_backed?: false,
    confirmation: :not_required,
    name: "get_public_call_result",
    description: "Read a public protocol call result by id within the caller's client scope.",
    category: "public_protocol",
    tags: ["public_protocol", "readback", "confirmation"],
    schema: [
      id: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      public_call_result: [type: :map, required: true]
    ]

  alias AllbertAssist.PublicProtocol.ResultReadback
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{id: id}, context) when is_binary(id) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, caller} <- ResultReadback.caller_from_context(context),
         {:ok, result} <- ResultReadback.get_for_client(id, caller.surface, caller.client_id) do
      completed(result, permission_decision)
    else
      false ->
        denied(id, permission_decision, :permission_denied)

      {:error, reason} ->
        denied(id, permission_decision, reason)
    end
  end

  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    denied(Map.get(params, :id) || Map.get(params, "id"), permission_decision, :invalid_id)
  end

  defp completed(result, permission_decision) do
    {:ok,
     %{
       message: "Public call #{result.id} is #{result.status}.",
       status: result.status,
       permission_decision: permission_decision,
       public_call_result: result,
       actions: [action(result, result.status, permission_decision)]
     }}
  end

  defp denied(id, permission_decision, reason) do
    result = %{
      id: id,
      status: :denied,
      error: reason
    }

    {:ok,
     %{
       message: "Public call result readback was denied: #{inspect(reason)}",
       status: :denied,
       permission_decision: permission_decision,
       public_call_result: result,
       error: reason,
       actions: [action(result, :denied, permission_decision)]
     }}
  end

  defp action(result, status, permission_decision) do
    %{
      name: "get_public_call_result",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      public_protocol_metadata: %{
        id: Map.get(result, :id),
        status: Map.get(result, :status)
      }
    }
  end
end
