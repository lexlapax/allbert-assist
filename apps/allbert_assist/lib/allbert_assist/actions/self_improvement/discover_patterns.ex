defmodule AllbertAssist.Actions.SelfImprovement.DiscoverPatterns do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :self_improvement_discovery,
    skill_backed?: false,
    confirmation: :not_required,
    name: "discover_patterns",
    description: "Discover repeated self-improvement patterns and persist inert suggestions.",
    category: "self_improvement",
    tags: ["self_improvement", "discovery", "read_only", "internal"],
    schema: [
      query: [type: :string, required: false],
      need: [type: :string, required: false],
      user_id: [type: :string, required: false],
      app_id: [type: :string, required: false],
      limit: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      suggestions: [type: {:list, :map}, required: true],
      diagnostics: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.SelfImprovement.Discovery

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    if PermissionGate.allowed?(permission_decision) do
      {:ok, result} = Discovery.discover(params, context)
      {:ok, completed(result, permission_decision)}
    else
      {:ok, denied(params, permission_decision, :permission_denied)}
    end
  end

  defp completed(result, permission_decision) do
    suggestions = Map.get(result, :suggestions, [])
    diagnostics = Map.get(result, :diagnostics, [])

    %{
      message: "Discovered #{length(suggestions)} self-improvement suggestion(s).",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      suggestions: suggestions,
      diagnostics: diagnostics,
      sources: Map.get(result, :sources, %{}),
      actions: [
        action(:completed, permission_decision, %{
          suggestions_count: length(suggestions),
          diagnostics_count: length(diagnostics),
          sources: Map.get(result, :sources, %{})
        })
      ]
    }
  end

  defp denied(params, permission_decision, reason) do
    %{
      message: "Self-improvement pattern discovery denied: #{inspect(reason)}.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      suggestions: [],
      diagnostics: [],
      error: reason,
      actions: [action(:denied, permission_decision, %{params: params, error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "discover_patterns",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      self_improvement_metadata: metadata
    }
  end
end
