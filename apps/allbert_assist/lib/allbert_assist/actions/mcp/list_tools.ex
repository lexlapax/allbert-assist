defmodule AllbertAssist.Actions.Mcp.ListTools do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :mcp_discovery,
    skill_backed?: false,
    confirmation: :not_required,
    name: "mcp_list_tools",
    description: "List descriptive MCP tool metadata for a configured server.",
    category: "mcp",
    tags: ["mcp", "tools", "read_only", "internal"],
    schema: [
      server_id: [type: :string, required: true],
      cursor: [type: :string, required: false],
      limit: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Mcp.Client
  alias AllbertAssist.Mcp.ServerConfig
  alias AllbertAssist.Runtime.Audit
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    server_id = field(params, :server_id)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, config} <- ServerConfig.resolve(server_id),
         {:ok, result} <- Client.list_tools(config, context, cursor: field(params, :cursor)) do
      tools = result.tools |> Enum.take(limit(params)) |> Enum.map(&redact_tool/1)
      audit(config, permission_decision, :succeeded, length(tools))
      {:ok, completed(server_id, permission_decision, tools, result)}
    else
      false -> {:ok, denied(server_id, permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(server_id, permission_decision, reason)}
    end
  end

  defp completed(server_id, permission_decision, tools, result) do
    %{
      message: "MCP tools for #{server_id}: #{length(tools)} listed.",
      status: :completed,
      permission_decision: permission_decision,
      server_id: server_id,
      tools: tools,
      next_cursor: result.next_cursor,
      protocol_version: result.protocol_version,
      actions: [
        action(:completed, permission_decision, %{server_id: server_id, tool_count: length(tools)})
      ]
    }
  end

  defp denied(server_id, permission_decision, reason) do
    %{
      message: "MCP tools could not be listed for #{server_id || "unknown"}: #{inspect(reason)}.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      server_id: server_id,
      tools: [],
      actions: [action(:denied, permission_decision, %{server_id: server_id, error: reason})]
    }
  end

  defp audit(config, permission_decision, event, count) do
    Audit.append(:mcp, event, config, permission_decision, %{
      action: "mcp_list_tools",
      status: :completed,
      tool_count: count
    })
  end

  defp redact_tool(tool) when is_map(tool) do
    %{
      "name" => Map.get(tool, "name"),
      "description" => Map.get(tool, "description"),
      "inputSchema" => Map.get(tool, "inputSchema")
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "mcp_list_tools",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      mcp_metadata: metadata
    }
  end

  defp limit(params) do
    case field(params, :limit) do
      value when is_integer(value) and value > 0 -> min(value, 100)
      _value -> 100
    end
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil
end
