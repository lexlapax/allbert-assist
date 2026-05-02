defmodule AllbertAssist.Actions.Confirmations.ShowConfirmation do
  @moduledoc false

  use Jido.Action,
    name: "show_confirmation",
    description: "Show one durable confirmation request.",
    category: "confirmations",
    tags: ["confirmations", "read_only"],
    schema: [id: [type: :string, required: true]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Confirmations.Context
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{id: id}, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    case Confirmations.read(id) do
      {:ok, record} ->
        {:ok,
         %{
           message: "Confirmation #{id}: #{record["status"]}.",
           status: PermissionGate.response_status(permission_decision),
           permission_decision: permission_decision,
           confirmation: record,
           actions: [
             Context.action(record, "show_confirmation", :completed, %{
               permission_decision
               | permission: :read_only
             })
           ]
         }}

      {:error, reason} ->
        Context.denied("show_confirmation", :read_only, permission_decision, reason)
    end
  end
end
