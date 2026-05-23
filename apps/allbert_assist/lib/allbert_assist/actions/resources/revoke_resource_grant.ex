defmodule AllbertAssist.Actions.Resources.RevokeResourceGrant do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :confirmation_decide,
    exposure: :internal,
    execution_mode: :resource_grant_revoke,
    skill_backed?: false,
    confirmation: :not_required,
    name: "revoke_resource_grant",
    description: "Revoke a remembered resource grant.",
    category: "resources",
    tags: ["resources", "grants", "confirmation_decide"],
    schema: [
      id: [type: :string, required: true],
      reason: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Resources.GrantHandoff
  alias AllbertAssist.Resources.Grants
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{id: id} = params, context) do
    permission_decision = PermissionGate.authorize(:confirmation_decide, context)

    if PermissionGate.allowed?(permission_decision) do
      revoke(id, params, context, permission_decision)
    else
      denied(permission_decision, :permission_denied)
    end
  end

  defp revoke(id, params, context, permission_decision) do
    attrs = %{
      reason: Map.get(params, :reason),
      actor: actor(context),
      channel: channel(context),
      surface: surface(context)
    }

    case Grants.revoke(id, attrs) do
      {:ok, grant} ->
        grant = GrantHandoff.summary(grant)

        {:ok,
         %{
           message: "Resource grant #{id} revoked.",
           status: :completed,
           permission_decision: permission_decision,
           grant: grant,
           actions: [
             %{
               name: "revoke_resource_grant",
               status: :completed,
               permission: :confirmation_decide,
               permission_decision: permission_decision,
               resource_grants: %{revoked: grant}
             }
           ]
         }}

      {:error, reason} ->
        denied(permission_decision, reason)
    end
  end

  defp denied(permission_decision, reason) do
    {:ok,
     %{
       message: "Resource grant revoke failed: #{inspect(reason)}",
       status: :denied,
       error: reason,
       permission_decision: permission_decision,
       actions: [
         %{
           name: "revoke_resource_grant",
           status: :denied,
           permission: :confirmation_decide,
           permission_decision: permission_decision,
           resource_grants: %{error: reason}
         }
       ]
     }}
  end

  defp actor(context), do: field(context, :actor, "local")
  defp channel(context), do: field(context, :channel, :unknown)
  defp surface(context), do: field(context, :surface, "resource_grants")

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
