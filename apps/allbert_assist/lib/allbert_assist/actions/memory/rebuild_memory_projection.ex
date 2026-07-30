defmodule AllbertAssist.Actions.Memory.RebuildMemoryProjection do
  @moduledoc "Reconcile pending Forget work, then rebuild the daemon-owned Memory projection."

  use AllbertAssist.Action,
    permission: :memory_write,
    exposure: :internal,
    execution_mode: :memory_index_compile,
    skill_backed?: false,
    confirmation: :not_required,
    resumable?: false,
    retry_safety: :safe,
    name: "rebuild_memory_projection",
    description: "Complete pending Memory recovery and promote a verified projection generation.",
    category: "memory",
    tags: ["memory", "projection", "rebuild", "managed-job"],
    schema: [
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      result: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Memory.Context
  alias AllbertAssist.Drafts.Promotion, as: DraftPromotion
  alias AllbertAssist.Memory.Forget
  alias AllbertAssist.Memory.Projection
  alias AllbertAssist.Memory.ProposalReview
  alias AllbertAssist.Memory.Proposals
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    decision = PermissionGate.authorize(:memory_write, context)

    with true <- PermissionGate.allowed?(decision),
         false <- is_nil(Process.whereis(Projection)),
         {:ok, user_id} <- Context.user_id(params, context) do
      rebuild(decision, user_id)
    else
      false -> denied(decision)
      true -> error(decision, :memory_projection_owner_unavailable)
      {:error, reason} -> error(decision, reason)
    end
  end

  defp rebuild(decision, user_id) do
    with {:ok, recovery} <- Forget.reconcile_pending(),
         {:ok, stale_recovery} <- Proposals.reconcile_unavailable(user_id),
         {:ok, proposal_recovery} <- ProposalReview.reconcile_applying(),
         :ok <- recovery_complete(proposal_recovery),
         {:ok, batch_recovery} <- ProposalReview.reconcile_batches(),
         :ok <- recovery_complete(batch_recovery),
         {:ok, legacy_draft_recovery} <- DraftPromotion.reconcile_memory_drafts(),
         :ok <- recovery_complete(legacy_draft_recovery),
         {:ok, projection} <- rebuild_after_recovery(recovery) do
      result = %{
        recovery: recovery,
        stale_recovery: stale_recovery,
        proposal_recovery: proposal_recovery,
        batch_recovery: batch_recovery,
        legacy_draft_recovery: legacy_draft_recovery,
        projection: projection
      }

      {:ok,
       %{
         message:
           "Memory projection is ready; recovered #{recovery.completed_count} pending Forget operation(s), " <>
             "#{proposal_recovery.completed_count} applying proposal(s), and " <>
             "#{batch_recovery.completed_count} applying batch(es); scrubbed " <>
             "#{legacy_draft_recovery.completed_count} committed legacy draft(s).",
         status: :completed,
         permission_decision: decision,
         result: result,
         actions: [action(:completed, decision) |> Map.put(:result, result)]
       }}
    else
      {:error, reason} -> error(decision, reason)
    end
  end

  defp rebuild_after_recovery(%{projection_replaced?: true}) do
    status = Projection.status()

    {:ok,
     %{
       generation_id: status.control["current_generation_id"],
       projection_revision: status.control["projection_revision"],
       recovered_generation?: true
     }}
  end

  defp rebuild_after_recovery(%{projection_replaced?: false}), do: Projection.rebuild()

  defp recovery_complete(%{retryable_error_count: 0}), do: :ok
  defp recovery_complete(summary), do: {:error, {:memory_recovery_incomplete, summary}}

  defp denied(decision) do
    {:ok,
     %{
       message: decision.reason,
       status: PermissionGate.response_status(decision),
       permission_decision: decision,
       actions: [action(:denied, decision)]
     }}
  end

  defp error(decision, reason) do
    guidance =
      if reason == :memory_projection_owner_unavailable do
        " Attach to the running Allbert daemon and retry; one-shot commands do not open projection databases."
      else
        ""
      end

    {:ok,
     %{
       message: "Unable to rebuild Memory projection: #{inspect(reason)}.#{guidance}",
       status: :error,
       error: reason,
       permission_decision: decision,
       actions: [action(:error, decision) |> Map.put(:error, reason)]
     }}
  end

  defp action(status, decision) do
    %{
      name: "rebuild_memory_projection",
      status: status,
      permission: :memory_write,
      permission_decision: decision
    }
  end
end
