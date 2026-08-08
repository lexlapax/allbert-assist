defmodule AllbertAssist.Actions.Memory.ForgetMemoryClaim do
  @moduledoc "Destructively Forget one exact Memory claim after explicit confirmation."

  use AllbertAssist.Action,
    registry_order: 165,
    permission: :memory_write,
    exposure: :internal,
    execution_mode: :memory_forget,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "forget_memory_claim",
    description: "Preview and confirm tombstone-first Forget for one exact Memory claim.",
    category: "memory",
    tags: ["memory", "forget", "confirmation", "destructive"],
    schema: [
      claim_id: [type: :string, required: true],
      user_id: [type: :string, required: false],
      reason_code: [type: :string, required: false],
      expected_tail_digest: [type: :string, required: false],
      actor: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      preview: [type: :map, required: false],
      disclosure: [type: :string, required: false],
      confirmation_id: [type: :string, required: false],
      result: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Memory.Context
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Memory.Forget
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) when is_map(params) do
    decision = PermissionGate.authorize(:memory_write, context)

    with true <- PermissionGate.allowed?(decision),
         {:ok, claim_id} <- required(value(params, :claim_id), :missing_claim_id),
         {:ok, user_id} <- Context.user_id(params, context),
         {:ok, reason_code} <- reason_code(value(params, :reason_code)) do
      if approval_resume?(context) do
        forget(params, claim_id, reason_code, decision)
      else
        preview(claim_id, user_id, reason_code, context, decision)
      end
    else
      false -> denied(decision)
      {:error, reason} -> error(decision, reason)
    end
  end

  def run(_params, context),
    do: error(PermissionGate.authorize(:memory_write, context), :missing_claim_id)

  defp preview(claim_id, user_id, reason_code, context, decision) do
    actor = Map.get(context, :actor, user_id)

    with {:ok, preview} <- Forget.preview(claim_id),
         {:ok, confirmation} <-
           create_confirmation(preview, user_id, actor, reason_code, context, decision) do
      {:ok,
       response_needs_confirmation(
         "Memory Forget requires explicit approval: #{confirmation["id"]}. #{preview.disclosure}",
         %{
           permission_decision: decision,
           preview: preview.current,
           disclosure: preview.disclosure,
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [action(:needs_confirmation, decision, claim_id, confirmation["id"])]
         }
       )}
    else
      {:error, reason} -> error(decision, reason)
    end
  end

  defp create_confirmation(preview, user_id, actor, reason_code, context, decision) do
    Confirmations.create(
      %{
        origin: origin(context, user_id),
        target_action: %{name: "forget_memory_claim", module: inspect(__MODULE__)},
        target_permission: :memory_write,
        target_execution_mode: :memory_forget,
        security_decision: decision,
        params_summary: %{
          claim_id: preview.claim_id,
          expected_tail_digest: preview.expected_tail_digest,
          reason_code: reason_code,
          normalizer_version: 1,
          disclosure: preview.disclosure,
          user_id: user_id
        },
        resume_params_ref: %{
          claim_id: preview.claim_id,
          expected_tail_digest: preview.expected_tail_digest,
          reason_code: reason_code,
          actor: actor,
          user_id: user_id
        }
      },
      context
    )
  end

  defp forget(params, claim_id, reason_code, decision) do
    with {:ok, expected_tail} <-
           required(value(params, :expected_tail_digest), :missing_confirmation_binding),
         {:ok, actor} <- required(value(params, :actor), :missing_confirmation_binding) do
      case Forget.forget(claim_id, expected_tail, actor, reason_code) do
        {:ok, result} -> completed(decision, safe_result(result), claim_id)
        {:error, reason} -> recovery_or_error(decision, claim_id, reason)
      end
    else
      {:error, reason} -> error(decision, reason)
    end
  end

  defp recovery_or_error(decision, claim_id, reason) do
    case Forget.recovery_status(claim_id) do
      {:ok, %{phase: :pending} = recovery} ->
        completed(
          decision,
          Map.merge(recovery, %{status: :cleanup_pending, cleanup_error: safe_error(reason)}),
          claim_id
        )

      _other ->
        error(decision, reason)
    end
  end

  defp completed(decision, result, claim_id) do
    {:ok,
     %{
       message: completed_message(result),
       status: :completed,
       permission_decision: decision,
       result: result,
       actions: [action(:completed, decision, claim_id, nil) |> Map.put(:result, result)]
     }}
  end

  defp safe_result(%{status: status, tombstone: tombstone}) do
    %{
      status: status,
      claim_id: tombstone["claim_id"],
      deleted_at: tombstone["deleted_at"],
      reason_code: tombstone["reason_code"],
      phase: String.to_existing_atom(tombstone["phase"])
    }
  end

  defp completed_message(%{status: :cleanup_pending}),
    do: "Memory claim is logically forgotten; content-free cleanup recovery remains pending."

  defp completed_message(_result), do: "Memory claim Forget completed."

  defp safe_error(reason) when is_atom(reason), do: reason
  defp safe_error({reason, _details}) when is_atom(reason), do: reason
  defp safe_error(_reason), do: :forget_cleanup_failed

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
       message: "Unable to Forget Memory claim: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: decision,
       actions: [action(:error, decision, nil, nil) |> Map.put(:error, safe_error(reason))]
     }}
  end

  defp action(status, decision, claim_id, confirmation_id) do
    %{
      name: "forget_memory_claim",
      status: status,
      permission: :memory_write,
      permission_decision: decision,
      claim_id: claim_id,
      confirmation_id: confirmation_id
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp reason_code(nil), do: {:ok, "operator_requested"}

  defp reason_code(value) when value in ~w[operator_requested privacy incorrect expired],
    do: {:ok, value}

  defp reason_code(_value), do: {:error, :invalid_forget_reason_code}

  defp approval_resume?(%{confirmation: %{approved?: true}}), do: true
  defp approval_resume?(%{"confirmation" => %{"approved?" => true}}), do: true
  defp approval_resume?(_context), do: false

  defp required(value, _reason) when is_binary(value) and value != "", do: {:ok, value}
  defp required(_value, reason), do: {:error, reason}
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
