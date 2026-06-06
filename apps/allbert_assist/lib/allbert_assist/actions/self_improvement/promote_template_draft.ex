defmodule AllbertAssist.Actions.SelfImprovement.PromoteTemplateDraft do
  @moduledoc false

  @permission :dynamic_codegen_request

  use AllbertAssist.Action,
    permission: :dynamic_codegen_request,
    exposure: :internal,
    execution_mode: :template_dynamic_draft,
    skill_backed?: false,
    confirmation: :not_required,
    name: "promote_template_draft",
    description:
      "Promote an inert template-backed self-improvement draft into a v0.37 dynamic draft.",
    category: "self_improvement",
    tags: ["self_improvement", "drafts", "templates", "dynamic_codegen_request"],
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

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Drafts.Store
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{id: id}, context) when is_binary(id) and id != "" do
    permission_decision = PermissionGate.authorize(@permission, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, draft} <- Store.show_draft(id, kind: "template_backed"),
         :ok <- require_promotable(draft),
         {:ok, template} <- template_payload(draft),
         {:ok, response} <- create_template_draft(template, context),
         :ok <- ensure_template_completed(response),
         result <- promotion_result(response, context),
         {:ok, promoted} <-
           Store.promote_draft(id, kind: "template_backed", promotion: result) do
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

  defp template_payload(%{payload: %{"template" => template}}) when is_map(template) do
    pattern_id = Map.get(template, "pattern_id")
    params = Map.get(template, "params")

    cond do
      not is_binary(pattern_id) or pattern_id == "" -> {:error, :template_pattern_id_required}
      not is_map(params) or params == %{} -> {:error, :template_params_required}
      true -> {:ok, %{pattern_id: pattern_id, params: params}}
    end
  end

  defp template_payload(_draft), do: {:error, :template_payload_missing}

  defp create_template_draft(template, context) do
    Runner.run(
      "create_from_template",
      %{
        pattern_id: template.pattern_id,
        mode: "live_integration",
        params: template.params
      },
      context
    )
  end

  defp ensure_template_completed(%{status: :completed}), do: :ok

  defp ensure_template_completed(response) do
    {:error, Map.get(response, :error, {:template_create_failed, Map.get(response, :status)})}
  end

  defp promotion_result(%{draft: dynamic_draft}, context) do
    %{
      target: "dynamic_template_draft",
      dynamic_draft_slug: dynamic_draft.slug,
      dynamic_draft_root: dynamic_draft.root,
      template_pattern_id: dynamic_draft.template_pattern_id,
      gate_status: dynamic_draft.gate_status,
      promoted_by: actor(context)
    }
  end

  defp completed(permission_decision, draft, response, result) do
    %{
      message:
        "Promoted template-backed draft #{draft.id} into dynamic draft #{result.dynamic_draft_slug}.",
      status: :completed,
      permission_decision: permission_decision,
      draft: draft,
      dynamic_draft: response.draft,
      template_response: response,
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
      message: "Template-backed self-improvement draft promotion was denied: #{inspect(reason)}",
      status: denied_status(permission_decision, reason),
      permission_decision: permission_decision,
      error: reason,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "promote_template_draft",
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
