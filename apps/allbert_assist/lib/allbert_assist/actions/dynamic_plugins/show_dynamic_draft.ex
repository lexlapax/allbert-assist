defmodule AllbertAssist.Actions.DynamicPlugins.ShowDynamicDraft do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :read_only,
    skill_backed?: false,
    confirmation: :not_required,
    name: "show_dynamic_draft",
    description: "Show v0.37 dynamic draft metadata.",
    category: "dynamic_plugins",
    tags: ["dynamic_plugins", "drafts", "read_only"],
    schema: [
      slug: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      draft: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{slug: slug}, context) when is_binary(slug) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    if PermissionGate.allowed?(permission_decision) do
      show(slug, permission_decision)
    else
      {:ok, denied(permission_decision, :permission_denied)}
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    {:ok, denied(permission_decision, :slug_required)}
  end

  defp show(slug, permission_decision) do
    case DynamicPlugins.show_draft(slug) do
      {:ok, draft} ->
        {:ok,
         %{
           message: "Dynamic draft #{slug}: #{draft.tier}",
           status: :completed,
           draft: draft,
           actions: [action(:completed, permission_decision, %{slug: slug, tier: draft.tier})]
         }}

      {:error, reason} ->
        {:ok, denied(permission_decision, reason)}
    end
  end

  defp denied(permission_decision, reason) do
    %{
      message: "Dynamic draft lookup was denied or unavailable: #{inspect(reason)}",
      status: :denied,
      error: reason,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "show_dynamic_draft",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      dynamic_plugins_metadata: metadata
    }
  end
end
