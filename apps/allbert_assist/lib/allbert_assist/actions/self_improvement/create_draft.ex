defmodule AllbertAssist.Actions.SelfImprovement.CreateDraft do
  @moduledoc false

  @permission :dynamic_codegen_request
  @supported_types %{
    "trace_to_skill" => "skill",
    "trace_to_workflow" => "workflow",
    "memory_promotion" => "memory_promotion",
    "memory_update" => "memory_update"
  }

  use AllbertAssist.Action,
    permission: :dynamic_codegen_request,
    exposure: :internal,
    execution_mode: :self_improvement_draft,
    skill_backed?: false,
    confirmation: :not_required,
    name: "create_self_improvement_draft",
    description:
      "Create an inert skill or workflow draft from an accepted self-improvement suggestion.",
    category: "self_improvement",
    tags: ["self_improvement", "drafts", "dynamic_codegen_request", "internal"],
    schema: [
      suggestion_id: [type: :string, required: true],
      kind: [type: :string, required: false],
      id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      draft: [type: :map, required: false],
      suggestion: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Drafts.Store
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Tools.Discovery

  @impl true
  def run(%{suggestion_id: suggestion_id} = params, context) when is_binary(suggestion_id) do
    permission_decision = PermissionGate.authorize(@permission, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, suggestion} <- Discovery.get_suggestion(suggestion_id),
         :ok <- validate_suggestion(suggestion),
         {:ok, kind} <- draft_kind(suggestion, params),
         {:ok, draft, accepted_suggestion} <-
           draft_for_suggestion(kind, suggestion, params, context) do
      {:ok, completed(permission_decision, draft, accepted_suggestion)}
    else
      false -> {:ok, denied(permission_decision, :permission_denied)}
      {:error, reason} -> {:ok, denied(permission_decision, reason)}
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(@permission, context)
    {:ok, denied(permission_decision, :suggestion_id_required)}
  end

  defp validate_suggestion(%{provenance: "self_improvement", status: status})
       when status in ["pending", "accepted"],
       do: :ok

  defp validate_suggestion(%{provenance: provenance}),
    do: {:error, {:invalid_provenance, provenance}}

  defp draft_kind(suggestion, params) do
    metadata = Map.get(suggestion, :metadata, %{})
    implied = Map.get(@supported_types, suggestion.suggestion_type)
    requested = string_param(params, :kind) || Map.get(metadata, "proposed_draft_kind") || implied

    cond do
      implied == nil ->
        {:error, {:unsupported_suggestion_type_for_draft, suggestion.suggestion_type}}

      requested != implied ->
        {:error,
         {:draft_kind_mismatch, %{suggestion_type: suggestion.suggestion_type, kind: requested}}}

      true ->
        {:ok, implied}
    end
  end

  defp create_draft(kind, suggestion, params, context) do
    attrs = draft_attrs(kind, suggestion, params, context)

    case kind do
      "skill" -> Store.create_skill_draft(attrs)
      "workflow" -> Store.create_workflow_draft(attrs)
      kind when kind in ["memory_promotion", "memory_update"] -> Store.create_memory_draft(attrs)
    end
  end

  defp draft_for_suggestion(
         kind,
         %{status: "accepted", draft_id: draft_id} = suggestion,
         _params,
         _context
       )
       when is_binary(draft_id) and draft_id != "" do
    with {:ok, draft} <- Store.show_draft(draft_id, kind: kind) do
      {:ok, draft, suggestion}
    end
  end

  defp draft_for_suggestion(kind, suggestion, params, context) do
    with {:ok, draft} <- create_draft(kind, suggestion, params, context),
         {:ok, accepted} <- Discovery.accept_suggestion(suggestion.id, draft.id) do
      {:ok, draft, Discovery.suggestion_to_map(accepted)}
    end
  end

  defp draft_attrs(kind, suggestion, params, context) do
    metadata = Map.get(suggestion, :metadata, %{})
    summary = Map.get(metadata, "summary", "Self-improvement draft")

    %{
      id: string_param(params, :id),
      kind: kind,
      summary: summary,
      body: Map.get(metadata, "body", summary),
      category: Map.get(metadata, "category", "notes"),
      path: Map.get(metadata, "path"),
      source_suggestion_id: suggestion.id,
      evidence_refs: Map.get(metadata, "evidence_refs", []),
      provenance: %{
        source: "self_improvement",
        suggestion_type: suggestion.suggestion_type,
        operator_id: operator_id(context)
      }
    }
  end

  defp completed(permission_decision, draft, suggestion) do
    %{
      message: "Created #{draft.kind} draft #{draft.id}.",
      status: :completed,
      permission_decision: permission_decision,
      draft: draft,
      suggestion: suggestion,
      actions: [
        action(:completed, permission_decision, %{
          draft_id: draft.id,
          draft_kind: draft.kind,
          suggestion_id: suggestion.id
        })
      ]
    }
  end

  defp denied(permission_decision, reason) do
    %{
      message: "Self-improvement draft creation was denied or unavailable: #{inspect(reason)}",
      status: denied_status(permission_decision, reason),
      permission_decision: permission_decision,
      error: reason,
      actions: [action(:denied, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "create_self_improvement_draft",
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
