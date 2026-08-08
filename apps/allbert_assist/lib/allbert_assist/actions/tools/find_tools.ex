defmodule AllbertAssist.Actions.Tools.FindTools do
  @moduledoc false

  use AllbertAssist.Action,
    registry_order: 83,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :mcp_discovery,
    skill_backed?: false,
    confirmation: :not_required,
    name: "find_tools",
    description: "Find usable local tools and discovered tool candidates for an operator need.",
    category: "tools",
    tags: ["tools", "discovery", "read_only", "internal"],
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
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Security
  alias AllbertAssist.Tools.Finder
  alias AllbertAssist.Tools.Source.Local
  alias AllbertAssist.Tools.Source.McpRegistry
  alias AllbertAssist.Tools.ToolCandidate

  @impl true
  def run(params, context) do
    permission_decision = Security.authorize(:read_only, context)
    tool_discovery_decision = Security.authorize(:tool_discovery, context)
    query = query(params)

    if Security.allowed?(permission_decision) do
      {sources, source_diagnostics} = source_plan(tool_discovery_decision)

      {:ok, %{candidates: candidates, diagnostics: diagnostics}} =
        Finder.find(query, %{context: context, limit: limit(params), sources: sources})

      {:ok, completed(query, candidates, source_diagnostics ++ diagnostics, permission_decision)}
    else
      {:ok, denied(query, permission_decision, :permission_denied)}
    end
  end

  defp source_plan(tool_discovery_decision) do
    if Security.allowed?(tool_discovery_decision) do
      {[Local, McpRegistry], []}
    else
      {[Local],
       [
         %{
           source: :mcp_registry,
           status: :denied,
           reason: ":tool_discovery denied"
         }
       ]}
    end
  end

  defp completed(query, candidates, diagnostics, permission_decision) do
    %{
      message: "Found #{length(candidates)} tool candidate(s) for #{inspect(query)}.",
      status: Response.permission_status(permission_decision),
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
      message: "Tool discovery denied for #{inspect(query)}: #{inspect(reason)}.",
      status: Response.permission_status(permission_decision),
      permission_decision: permission_decision,
      candidates: [],
      diagnostics: [],
      error: reason,
      actions: [action(:denied, permission_decision, %{query: query, error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "find_tools",
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
