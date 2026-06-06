defmodule AllbertAssist.Actions.SelfImprovement.PromoteCapabilityGapDraft do
  @moduledoc false

  @permission :dynamic_codegen_request

  use AllbertAssist.Action,
    permission: :dynamic_codegen_request,
    exposure: :internal,
    execution_mode: :dynamic_codegen,
    skill_backed?: false,
    confirmation: :not_required,
    name: "promote_capability_gap_draft",
    description:
      "Promote an inert capability-gap draft into a v0.37 source-bearing dynamic draft.",
    category: "self_improvement",
    tags: ["self_improvement", "drafts", "dynamic_codegen_request"],
    schema: [id: [type: :string, required: true]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      draft: [type: :map, required: false],
      dynamic_draft: [type: :map, required: false],
      result: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Drafts.Store
  alias AllbertAssist.DynamicPlugins
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{id: id}, context) when is_binary(id) and id != "" do
    permission_decision = PermissionGate.authorize(@permission, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, draft} <- Store.show_draft(id, kind: "capability_gap"),
         :ok <- require_promotable(draft),
         {:ok, gap} <- capability_gap_payload(draft),
         {:ok, response} <-
           DynamicPlugins.request_draft(request_attrs(gap), request_context(context)),
         result <- promotion_result(response, context),
         {:ok, promoted} <-
           Store.promote_draft(id, kind: "capability_gap", promotion: result) do
      {:ok, completed(permission_decision, promoted, response, result)}
    else
      false -> {:ok, denied(permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(permission_decision, reason)}
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(@permission, context)
    {:ok, denied(permission_decision, :id_required)}
  end

  defp require_promotable(%{tier: "draft", live_authority: false}), do: :ok
  defp require_promotable(%{tier: tier}), do: {:error, {:draft_not_promotable, tier}}
  defp require_promotable(_draft), do: {:error, :invalid_draft}

  defp capability_gap_payload(%{payload: %{"capability_gap" => gap}}) when is_map(gap),
    do: {:ok, gap}

  defp capability_gap_payload(_draft), do: {:error, :capability_gap_payload_missing}

  defp request_attrs(gap) do
    %{
      slug: Map.get(gap, "slug"),
      summary: Map.get(gap, "summary"),
      requested_capability: Map.get(gap, "requested_capability"),
      target_shapes: Map.get(gap, "target_shapes", ["action"]),
      objective_id: Map.get(gap, "objective_id"),
      step_id: Map.get(gap, "step_id"),
      user_id: Map.get(gap, "user_id"),
      constraints: Map.get(gap, "constraints", %{}),
      source: "operator",
      explicit_generation?: true
    }
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
      "step_id"
    ])
    |> Map.put(:source, "operator")
    |> Map.put(:explicit_generation?, true)
  end

  defp promotion_result(%{draft: dynamic_draft}, context) do
    %{
      target: "dynamic_codegen_draft",
      dynamic_draft_slug: dynamic_draft.slug,
      dynamic_draft_root: dynamic_draft.root,
      gate_status: dynamic_draft.gate_status,
      promoted_by: actor(context)
    }
  end

  defp completed(permission_decision, draft, response, result) do
    %{
      message:
        "Promoted capability-gap draft #{draft.id} into dynamic draft #{result.dynamic_draft_slug}.",
      status: :completed,
      permission_decision: permission_decision,
      draft: draft,
      dynamic_draft: response.draft,
      gap: response.gap,
      provider_profile: response.provider_profile,
      budget: response.budget,
      result: result,
      actions: [
        action(:completed, permission_decision, %{
          draft_id: draft.id,
          draft_kind: draft.kind,
          dynamic_draft_slug: result.dynamic_draft_slug,
          gate_status: result.gate_status
        })
      ]
    }
  end

  defp denied(permission_decision, reason) do
    %{
      message: "Capability-gap self-improvement draft promotion was denied: #{inspect(reason)}",
      status: denied_status(permission_decision, reason),
      permission_decision: permission_decision,
      error: reason,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "promote_capability_gap_draft",
      status: status,
      permission: @permission,
      permission_decision: permission_decision,
      self_improvement_metadata: metadata
    }
  end

  defp denied_status(permission_decision, :permission_denied),
    do: PermissionGate.response_status(permission_decision)

  defp denied_status(_permission_decision, _reason), do: :denied

  defp actor(context) do
    Map.get(context, :operator_id) || Map.get(context, "operator_id") ||
      Map.get(context, :user_id) || Map.get(context, "user_id") ||
      Map.get(context, :actor) || Map.get(context, "actor") || "local"
  end
end
