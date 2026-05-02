defmodule AllbertAssist.Actions.Confirmations.ApproveConfirmation do
  @moduledoc false

  use Jido.Action,
    name: "approve_confirmation",
    description: "Approve a durable confirmation request without bypassing target action policy.",
    category: "confirmations",
    tags: ["confirmations", "approval"],
    schema: [
      id: [type: :string, required: true],
      reason: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Confirmations.Context
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{id: id} = params, context) do
    permission_decision = PermissionGate.authorize(:confirmation_decide, context)

    if PermissionGate.allowed?(permission_decision) do
      approve(id, Map.get(params, :reason), context, permission_decision)
    else
      Context.denied(
        "approve_confirmation",
        :confirmation_decide,
        permission_decision,
        :permission_denied
      )
    end
  end

  defp approve(id, reason, context, permission_decision) do
    case Confirmations.resolve(id, :approved, Context.resolution_attrs(context, reason)) do
      {:ok, record} ->
        completed(record, permission_decision, idempotent?: false)

      {:error, {:confirmation_not_pending, ^id}} ->
        idempotent(id, permission_decision)

      {:error, reason} ->
        Context.denied("approve_confirmation", :confirmation_decide, permission_decision, reason)
    end
  end

  defp idempotent(id, permission_decision) do
    case Confirmations.read(id) do
      {:ok, record} ->
        completed(record, permission_decision, idempotent?: true)

      {:error, reason} ->
        Context.denied("approve_confirmation", :confirmation_decide, permission_decision, reason)
    end
  end

  defp completed(record, permission_decision, metadata) do
    {:ok,
     %{
       message: "Confirmation #{record["id"]} is #{record["status"]}.",
       status: :completed,
       permission_decision: permission_decision,
       confirmation: record,
       actions: [
         Context.action(
           record,
           "approve_confirmation",
           :completed,
           permission_decision,
           Map.new(metadata)
         )
       ]
     }}
  end
end
