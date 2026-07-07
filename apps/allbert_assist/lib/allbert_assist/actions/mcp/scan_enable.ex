defmodule AllbertAssist.Actions.Mcp.ScanEnable do
  @moduledoc """
  Enable opt-in MCP discovery scan management through the action spine.

  Enabling discovery writes Settings Central state and ensures the managed scan
  job exists, so the CLI may not call `Tools.Discovery.Scan.enable/1` directly.
  """

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :mcp_discovery_scan,
    skill_backed?: false,
    confirmation: :not_required,
    name: "mcp_scan_enable",
    description: "Enable MCP discovery scanning and ensure its managed job exists.",
    category: "mcp",
    tags: ["mcp", "discovery", "scan", "internal"],
    schema: [
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      scan_job: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Jobs.Identity
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Tools.Discovery.Scan

  @permission :settings_write

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(@permission, context)
    user_id = user_id(params, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, job} <- Scan.enable(scan_opts(params, context, user_id)) do
      completed(job, permission_decision, user_id)
    else
      {:allowed, false} -> denied(permission_decision, user_id, :permission_denied)
      {:error, reason} -> failed(permission_decision, user_id, reason)
    end
  end

  defp completed(job, permission_decision, user_id) do
    {:ok,
     %{
       message: "MCP discovery scan enabled.",
       status: :completed,
       permission_decision: permission_decision,
       scan_job: job,
       actions: [action(:completed, permission_decision, user_id, job, nil)]
     }}
  end

  defp denied(permission_decision, user_id, reason) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       error: reason,
       actions: [
         action(
           PermissionGate.response_status(permission_decision),
           permission_decision,
           user_id,
           nil,
           reason
         )
       ]
     }}
  end

  defp failed(permission_decision, user_id, reason) do
    {:ok,
     %{
       message: "MCP discovery scan enable failed: #{inspect(reason)}",
       status: :failed,
       permission_decision: permission_decision,
       error: reason,
       actions: [action(:failed, permission_decision, user_id, nil, reason)]
     }}
  end

  defp action(status, permission_decision, user_id, job, reason) do
    %{
      name: "mcp_scan_enable",
      status: status,
      permission: @permission,
      permission_decision: permission_decision,
      mcp_scan_metadata: %{
        command: "enable",
        user_id: user_id,
        job_id: job && job.id,
        error: reason
      }
    }
  end

  defp scan_opts(params, context, user_id) do
    %{user_id: user_id, operator_id: operator_id(params, context, user_id)}
  end

  defp user_id(params, context) do
    Identity.field(params, :user_id) || Identity.field(context, :user_id) ||
      Identity.field(Identity.field(context, :request) || %{}, :user_id) || "local"
  end

  defp operator_id(params, context, fallback) do
    Identity.field(params, :operator_id) || Identity.field(context, :scan_operator_id) || fallback
  end
end
