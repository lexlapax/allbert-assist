defmodule AllbertAssist.Actions.Memory.ShowMemoryProposal do
  @moduledoc "Show one Memory proposal with transient bounded Corpus context."

  use AllbertAssist.Action,
    registry_order: 167,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :memory_read,
    skill_backed?: false,
    confirmation: :not_required,
    retry_safety: :safe,
    name: "show_memory_proposal",
    description: "Show one Memory proposal and bounded redacted source context.",
    category: "memory",
    tags: ["memory", "proposals", "review", "read_only"],
    schema: [
      proposal_id: [type: :string, required: true],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      proposal: [type: :map, required: false],
      context: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Memory.Context
  alias AllbertAssist.Memory.ProposalReview
  alias AllbertAssist.Memory.Proposals
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    decision = PermissionGate.authorize(:read_only, context)

    with true <- PermissionGate.allowed?(decision),
         {:ok, proposal_id} <- required(value(params, :proposal_id), :missing_proposal_id),
         {:ok, user_id} <- Context.user_id(params, context),
         {:ok, preview} <- ProposalReview.preview(proposal_id, user_id) do
      proposal = Proposals.to_review_map(preview.proposal)

      {:ok,
       %{
         message: "Memory proposal #{proposal_id} is ready for review.",
         status: :completed,
         permission_decision: decision,
         proposal: proposal,
         context: preview.context,
         actions: [action(:completed, decision, proposal_id)]
       }}
    else
      false ->
        response(decision, PermissionGate.response_status(decision), decision.reason)

      {:error, reason} ->
        response(decision, :error, "Unable to show Memory proposal: #{inspect(reason)}", reason)
    end
  end

  defp response(decision, status, message, error \\ nil) do
    body = %{
      message: message,
      status: status,
      permission_decision: decision,
      actions: [action(status, decision, nil, error)]
    }

    {:ok, if(error, do: Map.put(body, :error, error), else: body)}
  end

  defp action(status, decision, proposal_id, error \\ nil) do
    %{
      name: "show_memory_proposal",
      status: status,
      permission: :read_only,
      permission_decision: decision
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
