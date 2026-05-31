defmodule AllbertAssist.Actions.Mcp.FindTools do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :tool_discovery,
    exposure: :internal,
    execution_mode: :mcp_discovery,
    skill_backed?: false,
    confirmation: :not_required,
    name: "find_mcp_tools",
    description: "Find inert MCP server candidates from enabled remote registries.",
    category: "mcp",
    tags: ["mcp", "tools", "discovery", "remote", "internal"],
    schema: [
      query: [type: :string, required: false],
      need: [type: :string, required: false],
      limit: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      candidates: [type: {:list, :map}, required: true],
      diagnostics: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Tools.Source.McpRegistry
  alias AllbertAssist.Tools.ToolCandidate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:tool_discovery, context)
    query = query(params)

    if PermissionGate.allowed?(permission_decision) do
      {:ok, %{candidates: candidates, diagnostics: diagnostics}} =
        McpRegistry.search_with_diagnostics(query, %{
          context: context,
          limit: limit(params),
          provider_opts: provider_opts(params),
          probe?: false
        })

      {:ok, completed(query, candidates, diagnostics, permission_decision)}
    else
      {:ok, denied(query, permission_decision, :permission_denied)}
    end
  end

  defp completed(query, candidates, diagnostics, permission_decision) do
    %{
      message: "Found #{length(candidates)} MCP registry candidate(s) for #{inspect(query)}.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      candidates: Enum.map(candidates, &ToolCandidate.to_map/1),
      diagnostics: diagnostics,
      actions: [
        action(:completed, permission_decision, %{
          query: query,
          count: length(candidates),
          diagnostics_count: length(diagnostics)
        })
      ]
    }
  end

  defp denied(query, permission_decision, reason) do
    %{
      message: "MCP registry discovery denied for #{inspect(query)}: #{inspect(reason)}.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      candidates: [],
      diagnostics: [],
      error: reason,
      actions: [action(:denied, permission_decision, %{query: query, error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "find_mcp_tools",
      status: status,
      permission: :tool_discovery,
      permission_decision: permission_decision,
      mcp_registry_metadata: metadata
    }
  end

  defp query(params), do: params |> field(:query, field(params, :need, "")) |> to_string()

  defp limit(params) do
    case field(params, :limit) do
      value when is_integer(value) and value > 0 -> value
      _value -> nil
    end
  end

  defp provider_opts(params) do
    case field(params, :provider_opts, %{}) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end

  defp field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
