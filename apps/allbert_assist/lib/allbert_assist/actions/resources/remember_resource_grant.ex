defmodule AllbertAssist.Actions.Resources.RememberResourceGrant do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :confirmation_decide,
    exposure: :internal,
    execution_mode: :resource_grant_remember,
    skill_backed?: false,
    confirmation: :not_required,
    name: "remember_resource_grant",
    description: "Remember a resource grant from a durable confirmation request.",
    category: "resources",
    tags: ["resources", "grants", "confirmation_decide"],
    schema: [
      id: [type: :string, required: true],
      remember_scope: [type: :string, required: true],
      resource_index: [type: :integer, required: false],
      remember_all: [type: :boolean, required: false],
      reason: [type: :string, required: false],
      expires_at: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Resources.GrantHandoff
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{id: id} = params, context) do
    permission_decision = PermissionGate.authorize(:confirmation_decide, context)

    if PermissionGate.allowed?(permission_decision) do
      remember(id, params, context, permission_decision)
    else
      denied(permission_decision, :permission_denied)
    end
  end

  defp remember(id, params, context, permission_decision) do
    with {:ok, record} <- Confirmations.read(id),
         {:ok, grants} <- GrantHandoff.remember_from_confirmation(record, params, context) do
      grants = Enum.map(grants, &GrantHandoff.summary/1)

      {:ok,
       %{
         message: "Remembered #{length(grants)} resource grant(s) from confirmation #{id}.",
         status: :completed,
         permission_decision: permission_decision,
         grants: grants,
         actions: [
           %{
             name: "remember_resource_grant",
             status: :completed,
             permission: :confirmation_decide,
             permission_decision: permission_decision,
             resource_grants: %{remembered: grants}
           }
         ]
       }}
    else
      {:error, reason} -> denied(permission_decision, reason)
    end
  end

  defp denied(permission_decision, reason) do
    {:ok,
     %{
       message: "Resource grant remember failed: #{inspect(reason)}",
       status: :denied,
       error: reason,
       permission_decision: permission_decision,
       actions: [
         %{
           name: "remember_resource_grant",
           status: :denied,
           permission: :confirmation_decide,
           permission_decision: permission_decision,
           resource_grants: %{error: reason}
         }
       ]
     }}
  end
end
