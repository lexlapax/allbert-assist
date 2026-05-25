defmodule AllbertAssist.Actions.DynamicPlugins.RequestDraft do
  @moduledoc """
  Internal action for explicit v0.37 dynamic draft requests.
  """

  use AllbertAssist.Action,
    permission: :skill_write,
    exposure: :internal,
    execution_mode: :dynamic_codegen,
    skill_backed?: false,
    confirmation: :not_required,
    name: "request_dynamic_draft",
    description: "Create inert dynamic draft metadata for an explicit capability gap.",
    category: "dynamic_plugins",
    tags: ["dynamic_plugins", "drafts", "codegen", "internal"],
    schema: [
      slug: [type: :string, required: false],
      summary: [type: :string, required: false],
      requested_capability: [type: :string, required: false],
      target_shapes: [type: {:list, :string}, required: false],
      objective_id: [type: :string, required: false],
      step_id: [type: :string, required: false],
      source: [type: :string, required: false],
      confidence: [type: :float, required: false],
      explicit_generation?: [type: :boolean, required: false],
      provider_calls_requested: [type: :integer, required: false],
      provider_usage_units_requested: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      draft: [type: :map, required: false],
      gap: [type: :map, required: false],
      provider_profile: [type: :map, required: false],
      budget: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:skill_write, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, result} <- DynamicPlugins.request_draft(params, request_context(context)) do
      {:ok, completed(permission_decision, result)}
    else
      false ->
        {:ok, denied(permission_decision)}

      {:error, reason} ->
        {:ok, failed(permission_decision, reason)}
    end
  end

  defp request_context(context) do
    context
    |> Map.take([
      :actor,
      "actor",
      :channel,
      "channel",
      :surface,
      "surface",
      :user_id,
      "user_id",
      :objective_id,
      "objective_id",
      :step_id,
      "step_id",
      :explicit_generation?,
      "explicit_generation?"
    ])
    |> Map.put_new(:source, "operator")
    |> Map.put_new(:explicit_generation?, true)
  end

  defp completed(permission_decision, result) do
    %{
      message: "Dynamic draft requested for #{result.draft.slug}.",
      status: :completed,
      permission_decision: permission_decision,
      draft: result.draft,
      gap: result.gap,
      provider_profile: result.provider_profile,
      budget: result.budget,
      diagnostics: result.diagnostics,
      actions: [action(:completed, permission_decision, result)]
    }
  end

  defp denied(permission_decision) do
    %{
      message: "Dynamic draft request is denied by Security Central.",
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      error: :permission_denied,
      actions: [action(:denied, permission_decision, %{error: :permission_denied})]
    }
  end

  defp failed(permission_decision, reason) do
    %{
      message: "Could not request dynamic draft: #{inspect(reason)}",
      status: :denied,
      permission_decision: permission_decision,
      error: reason,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "request_dynamic_draft",
      status: status,
      permission: :skill_write,
      permission_decision: permission_decision,
      dynamic_plugin_metadata: metadata
    }
  end
end
