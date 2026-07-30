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

  alias AllbertAssist.Memory.Forget
  alias AllbertAssist.Memory.Projection
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(_params, context) do
    decision = PermissionGate.authorize(:memory_write, context)

    cond do
      not PermissionGate.allowed?(decision) ->
        denied(decision)

      is_nil(Process.whereis(Projection)) ->
        error(decision, :memory_projection_owner_unavailable)

      true ->
        rebuild(decision)
    end
  end

  defp rebuild(decision) do
    with {:ok, recovery} <- Forget.reconcile_pending(),
         {:ok, projection} <- rebuild_after_recovery(recovery) do
      result = %{recovery: recovery, projection: projection}

      {:ok,
       %{
         message:
           "Memory projection is ready; recovered #{recovery.completed_count} pending Forget operation(s).",
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
