defmodule AllbertAssist.Actions.Memory.RestoreMemoryClaim do
  @moduledoc "Restore one archived Memory claim through the canonical claim writer."

  use AllbertAssist.Action,
    permission: :memory_write,
    exposure: :internal,
    execution_mode: :memory_write,
    skill_backed?: false,
    confirmation: :not_required,
    resumable?: false,
    retry_safety: :safe,
    name: "restore_memory_claim",
    description: "Restore one reversibly archived Memory claim.",
    category: "memory",
    tags: ["memory", "restore"],
    schema: [
      claim_id: [type: :string, required: true],
      user_id: [type: :string, required: false],
      expected_tail_digest: [type: :string, required: false],
      revision_id: [type: :string, required: false],
      transition_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      restored: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Memory.Context
  alias AllbertAssist.Memory.ClaimLifecycle
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = PermissionGate.authorize(:memory_write, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, claim_id} <- required(value(params, :claim_id), :missing_claim_id),
         {:ok, user_id} <- Context.user_id(params, context),
         {:ok, preview} <- ClaimLifecycle.preview(claim_id, user_id),
         :ok <- exact_tail(preview, value(params, :expected_tail_digest)),
         {:ok, restored} <-
           ClaimLifecycle.transition(preview, :restore, user_id, lifecycle_ids(params)) do
      {:ok,
       %{
         message: "Restored Memory claim: #{preview.summary}",
         status: :completed,
         permission_decision: permission_decision,
         restored: restored,
         actions: [
           %{
             name: "restore_memory_claim",
             status: :completed,
             permission: :memory_write,
             permission_decision: permission_decision,
             claim_id: claim_id,
             memory_path: restored.path,
             user_id: user_id
           }
         ]
       }}
    else
      false -> denied(permission_decision)
      {:error, reason} -> error(permission_decision, reason)
    end
  end

  def run(_params, context),
    do: error(PermissionGate.authorize(:memory_write, context), :missing_claim_id)

  defp exact_tail(_preview, nil), do: :ok
  defp exact_tail(%{expected_tail_digest: expected}, expected), do: :ok
  defp exact_tail(_preview, _expected), do: {:error, :stale_tail}

  defp lifecycle_ids(params) do
    case {value(params, :revision_id), value(params, :transition_id)} do
      {revision_id, transition_id} when is_binary(revision_id) and is_binary(transition_id) ->
        %{revision_id: revision_id, transition_id: transition_id}

      _other ->
        ClaimLifecycle.new_ids()
    end
  end

  defp denied(permission_decision) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [action(:denied, permission_decision, nil)]
     }}
  end

  defp error(permission_decision, reason) do
    {:ok,
     %{
       message: "Unable to restore Memory claim: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       actions: [action(:error, permission_decision, reason)]
     }}
  end

  defp action(status, permission_decision, error) do
    %{name: "restore_memory_claim", status: status, permission_decision: permission_decision}
    |> Map.put(:permission, :memory_write)
    |> maybe_put(:error, error)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp required(value, _reason) when is_binary(value) and value != "", do: {:ok, value}
  defp required(_value, reason), do: {:error, reason}
  defp value(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))
end
