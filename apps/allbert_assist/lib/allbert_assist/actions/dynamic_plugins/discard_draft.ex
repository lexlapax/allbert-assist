defmodule AllbertAssist.Actions.DynamicPlugins.DiscardDraft do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :settings_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "discard_dynamic_draft",
    description: "Discard an inert or rolled-back dynamic draft.",
    category: "dynamic_plugins",
    tags: ["dynamic_plugins", "drafts", "discard", "settings_write"],
    schema: [
      slug: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      draft: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.DynamicPlugins.Draft
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{slug: slug}, context) when is_binary(slug) do
    permission_decision = PermissionGate.authorize(:settings_write, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, draft} <- DynamicPlugins.discard_draft(slug, operator_id: operator_id(context)) do
      {:ok, completed(permission_decision, draft)}
    else
      false -> {:ok, denied(permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(permission_decision, reason)}
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:settings_write, context)
    {:ok, denied(permission_decision, :slug_required)}
  end

  defp completed(permission_decision, draft) do
    draft_summary = Draft.summary(draft)

    %{
      message: "Dynamic draft #{draft.slug} discarded.",
      status: :completed,
      permission_decision: permission_decision,
      draft: draft_summary,
      actions: [action(:completed, permission_decision, %{slug: draft.slug, tier: draft.tier})]
    }
  end

  defp denied(permission_decision, reason) do
    %{
      message: "Dynamic draft discard was denied or unavailable: #{inspect(reason)}",
      status: denied_status(permission_decision, reason),
      permission_decision: permission_decision,
      error: reason,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "discard_dynamic_draft",
      status: status,
      permission: :settings_write,
      permission_decision: permission_decision,
      dynamic_plugins_metadata: metadata
    }
  end

  defp denied_status(permission_decision, :permission_denied),
    do: PermissionGate.response_status(permission_decision)

  defp denied_status(_permission_decision, _reason), do: :denied

  defp operator_id(context) do
    Map.get(context, :operator_id) || Map.get(context, "operator_id") ||
      Map.get(context, :user_id) || Map.get(context, "user_id") ||
      Map.get(context, :actor) || Map.get(context, "actor")
  end
end
