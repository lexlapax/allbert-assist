defmodule AllbertAssist.Actions.Tools.FindLocalTools do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :mcp_discovery,
    skill_backed?: false,
    confirmation: :not_required,
    name: "find_local_tools",
    description:
      "Find currently usable local tools from actions, skills, and configured MCP servers.",
    category: "tools",
    tags: ["tools", "discovery", "local", "read_only", "internal"],
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

  alias AllbertAssist.Maps
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Tools.Source.Local
  alias AllbertAssist.Tools.ToolCandidate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    query = query(params)

    if PermissionGate.allowed?(permission_decision) do
      {:ok, %{candidates: candidates, diagnostics: diagnostics}} =
        Local.search_with_diagnostics(query, %{context: context, limit: limit(params)})

      {:ok, completed(query, candidates, diagnostics, permission_decision)}
    else
      {:ok, denied(query, permission_decision, :permission_denied)}
    end
  end

  defp completed(query, candidates, diagnostics, permission_decision) do
    %{
      message: "Found #{length(candidates)} local tool candidate(s) for #{inspect(query)}.",
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
      message: "Local tool discovery denied for #{inspect(query)}: #{inspect(reason)}.",
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
      name: "find_local_tools",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      tool_discovery_metadata: metadata
    }
  end

  defp query(params), do: params |> field(:query, field(params, :need, "")) |> to_string()

  defp limit(params) do
    case field(params, :limit) do
      value when is_integer(value) and value > 0 -> value
      _value -> nil
    end
  end

  defp field(map, key, default \\ nil), do: Maps.field(map, key, default)
end
