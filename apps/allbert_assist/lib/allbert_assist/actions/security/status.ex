defmodule AllbertAssist.Actions.Security.Status do
  @moduledoc """
  Read-only Security Central status action for operator surfaces.
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :security_status,
    skill_backed?: false,
    confirmation: :not_required,
    name: "security_status",
    description: "Show effective Security Central status and settings-backed permission posture.",
    category: "security",
    tags: ["security", "settings", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      security_status: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    status = Security.status(context)

    {:ok,
     %{
       message: message(status),
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       security_status: status,
       actions: [
         %{
           name: "security_status",
           status: :completed,
           permission: :read_only,
           permission_decision: permission_decision,
           security_metadata: %{
             permission_defaults: length(status.permission_defaults),
             safety_floors: length(status.safety_floors),
             secret_status: status.secret_status,
             settings_version_contract: %{
               status: status.settings_version_contract.status,
               counts: status.settings_version_contract.counts
             }
           }
         }
       ]
     }}
  end

  defp message(status) do
    """
    Security Central status:
    Permissions: #{length(status.permission_defaults)}
    Safety floors: #{length(status.safety_floors)}
    Settings versions: #{status.settings_version_contract.status}
    Secrets: #{status.secret_status.configured} configured, #{status.secret_status.missing} missing
    """
    |> String.trim()
  end
end
