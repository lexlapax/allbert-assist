defmodule AllbertAssist.Actions.Resources.ListResourceGrants do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :resource_grant_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_resource_grants",
    description: "List remembered resource grants.",
    category: "resources",
    tags: ["resources", "grants", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      grants: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Resources.GrantHandoff
  alias AllbertAssist.Resources.Grants
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with {:ok, grants} <- Grants.list() do
      grants = Enum.map(grants, &GrantHandoff.summary/1)

      {:ok,
       %{
         message: "Found #{length(grants)} remembered resource grant(s).",
         status: PermissionGate.response_status(permission_decision),
         permission_decision: permission_decision,
         grants: grants,
         actions: [
           %{
             name: "list_resource_grants",
             status: :completed,
             permission: :read_only,
             permission_decision: permission_decision,
             resource_grants: %{count: length(grants)}
           }
         ]
       }}
    end
  end
end
