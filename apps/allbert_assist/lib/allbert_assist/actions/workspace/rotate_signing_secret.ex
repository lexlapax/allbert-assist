defmodule AllbertAssist.Actions.Workspace.RotateSigningSecret do
  @moduledoc """
  Rotate the workspace Fragment signing secret through the registered action spine.

  The signing secret is durable runtime secret material under Allbert Home. Rotation
  therefore uses the existing `:settings_secret_write` permission class instead of
  letting the packaged CLI area call the store module directly.
  """

  use AllbertAssist.Action,
    permission: :settings_secret_write,
    exposure: :internal,
    execution_mode: :workspace_secret_rotation,
    skill_backed?: false,
    confirmation: :not_required,
    name: "rotate_workspace_signing_secret",
    description: "Rotate the workspace Fragment signing secret.",
    category: "workspace",
    tags: ["workspace", "fragments", "secrets", "internal"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      rotation: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Workspace.Fragment.SigningSecret

  @permission :settings_secret_write

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(@permission, context)

    if PermissionGate.allowed?(permission_decision) do
      rotate(permission_decision)
    else
      denied(permission_decision, :permission_denied)
    end
  end

  defp rotate(permission_decision) do
    case SigningSecret.rotate() do
      {:ok, rotation} -> completed(rotation, permission_decision)
      {:error, reason} -> failed(permission_decision, reason)
    end
  end

  defp completed(rotation, permission_decision) do
    {:ok,
     %{
       message: "Rotated workspace fragment signing secret.",
       status: :completed,
       permission_decision: permission_decision,
       rotation: rotation,
       actions: [action(:completed, permission_decision, rotation)]
     }}
  end

  defp denied(permission_decision, reason) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       error: reason,
       actions: [
         action(PermissionGate.response_status(permission_decision), permission_decision, %{})
       ]
     }}
  end

  defp failed(permission_decision, reason) do
    {:ok,
     %{
       message: "Workspace signing-secret rotation failed.",
       status: :failed,
       permission_decision: permission_decision,
       error: reason,
       actions: [action(:failed, permission_decision, %{error: reason})]
     }}
  end

  defp action(status, permission_decision, rotation) do
    %{
      name: "rotate_workspace_signing_secret",
      status: status,
      permission: @permission,
      permission_decision: permission_decision,
      workspace_metadata: %{
        path: Map.get(rotation, :path),
        fingerprint: Map.get(rotation, :fingerprint),
        previous_fingerprint: Map.get(rotation, :previous_fingerprint),
        error: Map.get(rotation, :error)
      }
    }
  end
end
