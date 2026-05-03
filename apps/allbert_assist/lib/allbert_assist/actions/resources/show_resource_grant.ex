defmodule AllbertAssist.Actions.Resources.ShowResourceGrant do
  @moduledoc false

  use Jido.Action,
    name: "show_resource_grant",
    description: "Show a remembered resource grant.",
    category: "resources",
    tags: ["resources", "grants", "read_only"],
    schema: [id: [type: :string, required: true]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Resources.GrantHandoff
  alias AllbertAssist.Resources.Grants
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{id: id}, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    case Grants.get(id) do
      {:ok, grant} ->
        grant = GrantHandoff.summary(grant)

        {:ok,
         %{
           message: "Resource grant #{id}.",
           status: PermissionGate.response_status(permission_decision),
           permission_decision: permission_decision,
           grant: grant,
           actions: [
             %{
               name: "show_resource_grant",
               status: :completed,
               permission: :read_only,
               permission_decision: permission_decision,
               resource_grants: %{id: id}
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
       message: "Resource grant lookup failed: #{inspect(reason)}",
       status: :denied,
       error: reason,
       permission_decision: permission_decision,
       actions: [
         %{
           name: "show_resource_grant",
           status: :denied,
           permission: :read_only,
           permission_decision: permission_decision,
           resource_grants: %{error: reason}
         }
       ]
     }}
  end
end
