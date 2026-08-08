defmodule AllbertAssist.Actions.Memory.ConfirmDestinationMemoryChain do
  @moduledoc "Confirm one unchanged foreign claim chain under the destination Home key."

  use AllbertAssist.Action,
    registry_order: 162,
    permission: :memory_write,
    exposure: :internal,
    execution_mode: :memory_write,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "confirm_destination_memory_chain",
    description: "Preview and confirm one exact foreign Memory claim chain.",
    category: "memory",
    tags: ["memory", "import", "confirmation"],
    schema: [
      claim_id: [type: :string, required: true],
      user_id: [type: :string, required: false],
      binding: [type: :map, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      preview: [type: :map, required: false],
      confirmation_id: [type: :string, required: false],
      result: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Memory.Context
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Memory.ClaimConfirmation
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) when is_map(params) do
    decision = PermissionGate.authorize(:memory_write, context)

    with true <- PermissionGate.allowed?(decision),
         {:ok, claim_id} <- required(value(params, :claim_id)),
         {:ok, user_id} <- Context.user_id(params, context) do
      if approval_resume?(context) do
        confirm(value(params, :binding), claim_id, decision)
      else
        preview(claim_id, user_id, context, decision)
      end
    else
      false -> denied(decision)
      {:error, reason} -> error(decision, reason)
    end
  end

  def run(_params, context),
    do: error(PermissionGate.authorize(:memory_write, context), :missing_claim_id)

  defp preview(claim_id, user_id, context, decision) do
    actor = Map.get(context, :actor, user_id)

    with {:ok, prepared} <- ClaimConfirmation.prepare_destination(claim_id, actor),
         {:ok, confirmation} <-
           create_confirmation(
             claim_id,
             user_id,
             prepared.binding,
             prepared.preview,
             context,
             decision
           ) do
      {:ok,
       response_needs_confirmation(
         "Review the exact foreign chain, then approve confirmation #{confirmation["id"]}. It remains quarantined until approval.",
         %{
           permission_decision: decision,
           preview: prepared.preview,
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [action(:needs_confirmation, decision, claim_id, confirmation["id"])]
         }
       )}
    else
      {:error, reason} -> error(decision, reason)
    end
  end

  defp create_confirmation(claim_id, user_id, binding, preview, context, decision) do
    Confirmations.create(
      %{
        origin: origin(context, user_id),
        target_action: %{name: "confirm_destination_memory_chain", module: inspect(__MODULE__)},
        target_permission: :memory_write,
        target_execution_mode: :memory_write,
        security_decision: decision,
        params_summary: %{
          claim_id: claim_id,
          expected_tail_digest: binding.expected_tail_digest,
          source_chain_digest: binding.source_chain_digest,
          record_count: preview.record_count,
          user_id: user_id
        },
        resume_params_ref: %{claim_id: claim_id, user_id: user_id, binding: binding}
      },
      context
    )
  end

  defp confirm(binding, claim_id, decision) when is_map(binding) do
    case ClaimConfirmation.confirm_destination(binding) do
      {:ok, result} ->
        {:ok,
         %{
           message: "Confirmed exact destination Memory chain for claim #{claim_id}.",
           status: :completed,
           permission_decision: decision,
           result: result,
           actions: [action(:completed, decision, claim_id, nil)]
         }}

      {:error, reason} ->
        error(decision, reason)
    end
  end

  defp confirm(_binding, _claim_id, decision), do: error(decision, :missing_confirmation_binding)

  defp denied(decision) do
    {:ok,
     %{
       message: decision.reason,
       status: PermissionGate.response_status(decision),
       permission_decision: decision,
       actions: [action(:denied, decision, nil, nil)]
     }}
  end

  defp error(decision, reason) do
    {:ok,
     %{
       message: "Unable to confirm destination Memory chain: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: decision,
       actions: [action(:error, decision, nil, nil) |> Map.put(:error, reason)]
     }}
  end

  defp action(status, decision, claim_id, confirmation_id) do
    %{
      name: "confirm_destination_memory_chain",
      status: status,
      permission: :memory_write,
      permission_decision: decision,
      claim_id: claim_id,
      confirmation_id: confirmation_id
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp approval_resume?(%{confirmation: %{approved?: true}}), do: true
  defp approval_resume?(%{"confirmation" => %{"approved?" => true}}), do: true
  defp approval_resume?(_context), do: false

  defp required(value) when is_binary(value) and value != "", do: {:ok, value}
  defp required(_value), do: {:error, :missing_claim_id}
  defp value(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))

  defp origin(context, user_id) do
    %{
      channel: Map.get(context, :channel, :unknown),
      actor: Map.get(context, :actor, user_id),
      user_id: user_id,
      session_id: Map.get(context, :session_id),
      surface: Map.get(context, :surface, "action")
    }
  end
end
