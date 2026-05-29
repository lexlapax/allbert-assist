defmodule AllbertAssist.Actions.Mcp.ListResources do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :mcp_discovery,
    skill_backed?: false,
    confirmation: :not_required,
    name: "mcp_list_resources",
    description: "List descriptive MCP resource metadata for a configured server.",
    category: "mcp",
    tags: ["mcp", "resources", "read_only", "internal"],
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
         {:ok, result} <- Client.list_resources(config, context, cursor: field(params, :cursor)) do
      resources = result.resources |> Enum.take(limit(params)) |> Enum.map(&redact_resource/1)
      audit(config, permission_decision, :succeeded, length(resources))
      {:ok, completed(server_id, permission_decision, resources, result)}
    else
      false -> {:ok, denied(server_id, permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(server_id, permission_decision, reason)}
    end
  end

  defp completed(server_id, permission_decision, resources, result) do
    %{
      message: "MCP resources for #{server_id}: #{length(resources)} listed.",
      status: :completed,
      permission_decision: permission_decision,
      server_id: server_id,
      resources: resources,
      next_cursor: result.next_cursor,
      protocol_version: result.protocol_version,
      actions: [
        action(:completed, permission_decision, %{
          server_id: server_id,
          resource_count: length(resources)
        })
      ]
    }
  end

  defp denied(server_id, permission_decision, reason) do
    %{
      message:
        "MCP resources could not be listed for #{server_id || "unknown"}: #{inspect(reason)}.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      server_id: server_id,
      resources: [],
      actions: [action(:denied, permission_decision, %{server_id: server_id, error: reason})]
    }
  end

  defp audit(config, permission_decision, event, count) do
    Audit.append(:mcp, event, config, permission_decision, %{
      action: "mcp_list_resources",
      status: :completed,
      resource_count: count
    })
  end

  defp redact_resource(resource) when is_map(resource) do
    %{
      "uri" => Map.get(resource, "uri"),
      "name" => Map.get(resource, "name"),
      "description" => Map.get(resource, "description"),
      "mimeType" => Map.get(resource, "mimeType")
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "mcp_list_resources",
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
