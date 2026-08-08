defmodule AllbertAssist.Actions.Search.PurgeSearchProjection do
  @moduledoc """
  Separately confirmed, crash-resumable purge of the disposable Search projection.

  Durable confirmation parameters are content-free and HMAC-bound to the exact
  target plus managed file/generation scope. Canonical conversation deletion is
  intentionally a different action.
  """

  use AllbertAssist.Action,
    registry_order: 64,
    permission: :search_manage,
    exposure: :internal,
    execution_mode: :search_purge,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "purge_search_projection",
    description: "Purge one confirmed ineligible target from every Search generation.",
    category: "search",
    tags: ["search", "purge", "destructive", "confirmation"],
    schema: [
      target_kind: [type: :any, required: true],
      target_ids: [type: {:list, :string}, required: false],
      source_classes: [type: {:list, :string}, required: false],
      operator_id: [type: :string, required: false],
      expected_eligibility_epoch: [type: :integer, required: false],
      preview_binding: [type: :string, required: false],
      key_ref: [type: :string, required: false],
      key_version: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      confirmation_id: [type: :string, required: false],
      preview: [type: :map, required: false],
      result: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Jobs.Identity
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Search.Projection
  alias AllbertAssist.Search.Purge
  alias AllbertAssist.Security.PermissionGate

  @action_name "purge_search_projection"
  @permission :search_manage

  @impl true
  def run(params, context) when is_map(params) do
    decision = PermissionGate.authorize(@permission, context)

    with true <- PermissionGate.allowed?(decision),
         {:ok, operator_id} <- Identity.user_id(params, context) do
      if approved_resume?(context),
        do: purge_now(params, operator_id, context, decision),
        else: preview_and_confirm(params, operator_id, context, decision)
    else
      false -> denied(decision)
      {:error, reason} -> failed(decision, reason)
    end
  end

  def run(_params, context),
    do: failed(PermissionGate.authorize(@permission, context), :invalid_params)

  def trace_safe_summary(:params, params) do
    %{
      target_kind: value(params, :target_kind),
      target_count: length(value(params, :target_ids, [])),
      source_classes: value(params, :source_classes, []),
      expected_eligibility_epoch: value(params, :expected_eligibility_epoch)
    }
  end

  def trace_safe_summary(:result, response) do
    %{
      status: Map.get(response, :status),
      phase: get_in(response, [:result, :phase]),
      target_kind: get_in(response, [:result, :target_kind])
    }
  end

  defp preview_and_confirm(params, operator_id, context, decision) do
    with {:ok, preview} <- Purge.preview(params, operator_id),
         {:ok, confirmation} <- create_confirmation(preview, context, decision) do
      confirmation_id = confirmation["id"] || confirmation[:id]

      {:ok,
       %{
         message: disclosure(preview, confirmation_id),
         status: :needs_confirmation,
         permission_decision: decision,
         confirmation: confirmation,
         confirmation_id: confirmation_id,
         preview: public_preview(preview),
         actions: [action(:needs_confirmation, decision, nil, confirmation_id)]
       }}
    else
      {:error, reason} -> failed(decision, reason)
    end
  end

  defp create_confirmation(preview, context, decision) do
    safe = %{
      target_kind: preview.target_kind,
      target_ids: preview.target_ids,
      source_classes: preview.source_classes,
      expected_eligibility_epoch: preview.expected_eligibility_epoch,
      preview_binding: preview.preview_binding,
      key_ref: preview.key_ref,
      key_version: preview.key_version
    }

    Confirmations.create(
      %{
        origin: Origin.from_context(context, @action_name),
        target_action: %{name: @action_name, module: inspect(__MODULE__)},
        target_permission: @permission,
        target_execution_mode: :search_purge,
        security_decision: decision,
        params_summary: public_preview(preview),
        resume_params_ref: safe
      },
      context
    )
  end

  defp purge_now(params, operator_id, context, decision) do
    confirmation_id = get_in(context, [:confirmation, :id])

    case Projection.purge(params, operator_id, confirmation_id) do
      {:ok, result} ->
        {:ok,
         %{
           message:
             "Search projection purge completed under its best-effort active-Home boundary; backups, snapshots, filesystem remnants, and storage hardware are outside the claim.",
           status: :completed,
           permission_decision: decision,
           result: result,
           actions: [action(:completed, decision, result, confirmation_id)]
         }}

      {:error, reason} ->
        failed(decision, reason)
    end
  end

  defp disclosure(preview, confirmation_id) do
    "Confirmation #{confirmation_id} will replace or remove #{length(preview.managed_files)} " <>
      "managed Search projection file(s) for #{preview.target_kind}. Canonical conversations, " <>
      "provider copies, backups, snapshots, filesystem remnants, and storage hardware are not deleted."
  end

  defp public_preview(preview) do
    Map.take(preview, [
      :target_kind,
      :target_ids,
      :source_classes,
      :expected_eligibility_epoch,
      :managed_files,
      :generation_ids,
      :preview_binding
    ])
  end

  defp denied(decision) do
    {:ok,
     %{
       message: decision.reason,
       status: PermissionGate.response_status(decision),
       permission_decision: decision,
       actions: [action(:denied, decision, nil, nil)]
     }}
  end

  defp failed(decision, reason) do
    {:ok,
     %{
       message: "Search projection purge failed: #{safe_error(reason)}.",
       status: :failed,
       error: reason,
       permission_decision: decision,
       actions: [action(:failed, decision, %{error: safe_error(reason)}, nil)]
     }}
  end

  defp action(status, decision, result, confirmation_id) do
    %{
      name: @action_name,
      status: status,
      permission: @permission,
      permission_decision: decision,
      result: result,
      confirmation_id: confirmation_id
    }
  end

  defp safe_error(reason) when is_atom(reason), do: reason
  defp safe_error({reason, _detail}) when is_atom(reason), do: reason
  defp safe_error(_reason), do: :search_purge_failed

  defp approved_resume?(%{confirmation: %{approved?: true}}), do: true
  defp approved_resume?(%{"confirmation" => %{"approved?" => true}}), do: true
  defp approved_resume?(_context), do: false

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
