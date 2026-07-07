defmodule AllbertAssist.Actions.Mcp.ScanRunOnce do
  @moduledoc "Run the managed MCP discovery scan once through the action spine."

  use AllbertAssist.Action,
    permission: :job_write,
    exposure: :internal,
    execution_mode: :mcp_discovery_scan,
    skill_backed?: false,
    confirmation: :not_required,
    name: "mcp_scan_run_once",
    description: "Run the managed MCP discovery scan once.",
    category: "mcp",
    tags: ["mcp", "discovery", "scan", "internal"],
    schema: [
      query: [type: :string, required: false],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      scan_run: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Jobs.Identity
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Tools.Discovery.Scan

  @permission :job_write

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(@permission, context)
    user_id = user_id(params, context)
    query = query(params)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, result} <-
           Scan.run_once(query,
             user_id: user_id,
             operator_id: operator_id(params, context, user_id),
             action_context: context
           ) do
      completed(result, permission_decision, user_id)
    else
      {:allowed, false} -> denied(permission_decision, user_id, :permission_denied)
      {:error, reason} -> failed(permission_decision, user_id, reason)
    end
  end

  defp completed(result, permission_decision, user_id) do
    {:ok,
     %{
       message: "MCP discovery scan ran once.",
       status: :completed,
       permission_decision: permission_decision,
       scan_run: result,
       actions: [action(:completed, permission_decision, user_id, result, nil)]
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
       message: "MCP discovery scan run-once failed: #{inspect(reason)}",
       status: :failed,
       permission_decision: permission_decision,
       error: reason,
       actions: [action(:failed, permission_decision, user_id, nil, reason)]
     }}
  end

  defp action(status, permission_decision, user_id, result, reason) do
    %{
      name: "mcp_scan_run_once",
      status: status,
      permission: @permission,
      permission_decision: permission_decision,
      mcp_scan_metadata: %{
        command: "run-once",
        user_id: user_id,
        job_id: nested_id(result, :job),
        run_id: nested_id(result, :run),
        error: reason
      }
    }
  end

  defp user_id(params, context) do
    Identity.field(params, :user_id) || Identity.field(context, :user_id) ||
      Identity.field(Identity.field(context, :request) || %{}, :user_id) || "local"
  end

  defp operator_id(params, context, fallback) do
    Identity.field(params, :operator_id) || Identity.field(context, :scan_operator_id) || fallback
  end

  defp query(params) do
    case Identity.field(params, :query) do
      value when is_binary(value) -> String.trim(value)
      nil -> ""
      value -> value |> to_string() |> String.trim()
    end
  end

  defp nested_id(nil, _key), do: nil

  defp nested_id(result, key) when is_map(result) do
    case Map.get(result, key) || Map.get(result, Atom.to_string(key)) do
      %{id: id} -> id
      %{"id" => id} -> id
      _other -> nil
    end
  end
end
