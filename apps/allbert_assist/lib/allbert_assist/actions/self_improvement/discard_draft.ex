defmodule AllbertAssist.Actions.SelfImprovement.DiscardDraft do
  @moduledoc false

  @permission :dynamic_codegen_discard

  use AllbertAssist.Action,
    permission: :dynamic_codegen_discard,
    exposure: :internal,
    execution_mode: :self_improvement_draft,
    skill_backed?: false,
    confirmation: :not_required,
    name: "discard_self_improvement_draft",
    description: "Discard an inert self-improvement skill or workflow draft.",
    category: "self_improvement",
    tags: ["self_improvement", "drafts", "discard", "dynamic_codegen_discard"],
    schema: [
      id: [type: :string, required: true],
      kind: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      draft: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Drafts.Store
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{id: id} = params, context) when is_binary(id) do
    permission_decision = PermissionGate.authorize(@permission, context)

    with true <- PermissionGate.allowed?(permission_decision),
         kind <- string_param(params, :kind),
         {:ok, draft} <- Store.discard_draft(id, kind: kind, operator_id: operator_id(context)) do
      {:ok, completed(permission_decision, draft)}
    else
      false -> {:ok, denied(permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(permission_decision, reason)}
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(@permission, context)
    {:ok, denied(permission_decision, :id_required)}
  end

  defp completed(permission_decision, draft) do
    %{
      message: "Self-improvement draft #{draft.id} discarded.",
      status: :completed,
      permission_decision: permission_decision,
      draft: draft,
      actions: [
        action(:completed, permission_decision, %{draft_id: draft.id, draft_kind: draft.kind})
      ]
    }
  end

  defp denied(permission_decision, reason) do
    %{
      message: "Self-improvement draft discard was denied or unavailable: #{inspect(reason)}",
      status: denied_status(permission_decision, reason),
      permission_decision: permission_decision,
      error: reason,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "discard_self_improvement_draft",
      status: status,
      permission: @permission,
      permission_decision: permission_decision,
      self_improvement_metadata: metadata
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

  defp string_param(params, key) do
    value = Map.get(params, key) || Map.get(params, Atom.to_string(key))

    if is_binary(value) and String.trim(value) != "" do
      String.trim(value)
    else
      nil
    end
  end
end
