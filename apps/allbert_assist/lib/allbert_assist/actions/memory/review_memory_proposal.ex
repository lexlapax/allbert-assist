defmodule AllbertAssist.Actions.Memory.ReviewMemoryProposal do
  @moduledoc "Apply one exact Memory proposal review decision."

  use AllbertAssist.Action,
    registry_order: 168,
    permission: :memory_write,
    exposure: :internal,
    execution_mode: :memory_write,
    skill_backed?: false,
    confirmation: :not_required,
    retry_safety: :safe,
    resumable?: true,
    name: "review_memory_proposal",
    description: "Keep, edit, or reject one exact Memory proposal revision.",
    category: "memory",
    tags: ["memory", "proposals", "review", "memory_write"],
    schema: [
      proposal_id: [type: :string, required: true],
      revision: [type: :integer, required: true],
      proposal_digest: [type: :string, required: true],
      operation: [type: :string, required: true],
      proposed_claim: [type: :map, required: false],
      span_provenance: [type: :map, required: false],
      claim_id: [type: :string, required: false],
      expected_tail_digest: [type: :string, required: false],
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
  alias AllbertAssist.Memory.ProposalReview
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission = PermissionGate.authorize(:memory_write, context)

    with true <- PermissionGate.allowed?(permission),
         {:ok, proposal_id} <- required(value(params, :proposal_id), :missing_proposal_id),
         {:ok, user_id} <- Context.user_id(params, context),
         {:ok, result} <-
           ProposalReview.review(
             proposal_id,
             %{
               revision: value(params, :revision),
               proposal_digest: value(params, :proposal_digest)
             },
             decision(params),
             "operator:" <> user_id
           ) do
      {:ok,
       %{
         message: "Memory proposal #{proposal_id} review finished with #{result.status}.",
         status: :completed,
         permission_decision: permission,
         result: result,
         actions: [action(:completed, permission, proposal_id)]
       }}
    else
      false ->
        response(permission, PermissionGate.response_status(permission), permission.reason)

      {:error, reason} ->
        response(
          permission,
          :error,
          "Unable to review Memory proposal: #{inspect(reason)}",
          reason
        )
    end
  end

  defp decision(params) do
    %{
      operation: value(params, :operation),
      proposed_claim: value(params, :proposed_claim),
      span_provenance: value(params, :span_provenance),
      claim_id: value(params, :claim_id),
      expected_tail_digest: value(params, :expected_tail_digest)
    }
  end

  defp response(permission, status, message, error \\ nil) do
    body = %{
      message: message,
      status: status,
      permission_decision: permission,
      actions: [action(status, permission, nil, error)]
    }

    {:ok, if(error, do: Map.put(body, :error, error), else: body)}
  end

  defp action(status, permission, proposal_id, error \\ nil) do
    %{
      name: "review_memory_proposal",
      status: status,
      permission: :memory_write,
      permission_decision: permission
    }
    |> maybe_put(:proposal_id, proposal_id)
    |> maybe_put(:error, error)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp required(value, _reason) when is_binary(value) and value != "", do: {:ok, value}
  defp required(_value, reason), do: {:error, reason}
  defp value(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))
end
