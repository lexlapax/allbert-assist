defmodule AllbertAssist.Actions.Memory.ListMemoryProposals do
  @moduledoc "List inert Memory proposals through the shared review DTO."

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :memory_read,
    skill_backed?: false,
    confirmation: :not_required,
    retry_safety: :safe,
    name: "list_memory_proposals",
    description: "List pending or applying Memory proposals for operator review.",
    category: "memory",
    tags: ["memory", "proposals", "review", "read_only"],
    schema: [
      user_id: [type: :string, required: false],
      namespace: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      proposals: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Memory.Context
  alias AllbertAssist.Memory.Proposals
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    decision = PermissionGate.authorize(:read_only, context)

    with true <- PermissionGate.allowed?(decision),
         {:ok, user_id} <- Context.user_id(params, context),
         {:ok, _reconciled} <- Proposals.reconcile_unavailable(user_id) do
      namespace = value(params, :namespace) || "default"
      proposals = Proposals.list(user_id, namespace) |> Enum.map(&Proposals.to_review_map/1)

      {:ok,
       %{
         message: "Found #{length(proposals)} Memory proposal(s) awaiting review.",
         status: :completed,
         permission_decision: decision,
         proposals: proposals,
         actions: [action(:completed, decision, %{proposal_count: length(proposals)})]
       }}
    else
      false -> denied(decision)
      {:error, reason} -> error(decision, reason)
    end
  end

  defp denied(decision) do
    {:ok,
     %{
       message: decision.reason,
       status: PermissionGate.response_status(decision),
       permission_decision: decision,
       proposals: [],
       actions: [action(:denied, decision)]
     }}
  end

  defp error(decision, reason) do
    {:ok,
     %{
       message: "Unable to list Memory proposals: #{inspect(reason)}",
       status: :error,
       error: reason,
       permission_decision: decision,
       proposals: [],
       actions: [action(:error, decision, %{error: reason})]
     }}
  end

  defp action(status, decision, extra \\ %{}) do
    Map.merge(
      %{
        name: "list_memory_proposals",
        status: status,
        permission: :read_only,
        permission_decision: decision
      },
      extra
    )
  end

  defp value(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))
end
