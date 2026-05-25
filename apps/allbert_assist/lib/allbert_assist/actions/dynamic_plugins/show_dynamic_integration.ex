defmodule AllbertAssist.Actions.DynamicPlugins.ShowDynamicIntegration do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :read_only,
    skill_backed?: false,
    confirmation: :not_required,
    name: "show_dynamic_integration",
    description: "Show v0.37 dynamic integration metadata.",
    category: "dynamic_plugins",
    tags: ["dynamic_plugins", "integrations", "read_only"],
    schema: [
      slug: [type: :string, required: true],
      revision: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      integration: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{slug: slug} = params, context) when is_binary(slug) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    if PermissionGate.allowed?(permission_decision) do
      show(slug, Map.get(params, :revision), permission_decision)
    else
      {:ok, denied(permission_decision, :permission_denied)}
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    {:ok, denied(permission_decision, :slug_required)}
  end

  defp show(slug, revision, permission_decision) do
    case DynamicPlugins.show_integration(slug, revision) do
      {:ok, integration} ->
        {:ok,
         %{
           message: "Dynamic integration #{slug}: #{integration.tier}",
           status: :completed,
           integration: integration,
           actions: [
             action(:completed, permission_decision, %{
               slug: slug,
               revision: integration.revision,
               tier: integration.tier
             })
           ]
         }}

      {:error, reason} ->
        {:ok, denied(permission_decision, reason)}
    end
  end

  defp denied(permission_decision, reason) do
    %{
      message: "Dynamic integration lookup was denied or unavailable: #{inspect(reason)}",
      status: :denied,
      error: reason,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "show_dynamic_integration",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      dynamic_plugins_metadata: metadata
    }
  end
end
