defmodule AllbertAssist.Actions.Intent.ListIntentCandidates do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :read_only,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_intent_candidates",
    description: "List bounded registry-aware intent candidates for text without executing them.",
    category: "intent",
    tags: ["intent", "read_only", "internal"],
    schema: [
      text: [type: :string, required: false],
      active_app: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Intent.Candidate
  alias AllbertAssist.Intent.Engine
  alias AllbertAssist.Intent.Ranker
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    request = request(params, context)

    candidates =
      request
      |> Engine.collect_candidates()
      |> Ranker.rank(request)
      |> Candidate.bound(total_limit: max_candidates())
      |> Candidate.to_maps()

    {:ok,
     %{
       message: message(candidates),
       status: PermissionGate.response_status(permission_decision),
       candidates: candidates,
       actions: [action(:completed, permission_decision, candidates)]
     }}
  end

  defp request(params, context) do
    context
    |> Map.get(:request, %{})
    |> Map.merge(%{
      text: Map.get(params, :text, ""),
      active_app: Map.get(params, :active_app) || get_in(context, [:request, :active_app])
    })
  end

  defp message([]), do: "No intent candidates."

  defp message(candidates) do
    rendered =
      candidates
      |> Enum.take(10)
      |> Enum.map(&"- #{&1.kind}/#{&1.id}: score=#{&1.score}")
      |> Enum.join("\n")

    "Intent candidates:\n\n#{rendered}"
  end

  defp action(status, permission_decision, candidates) do
    %{
      name: "list_intent_candidates",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      intent_metadata: %{candidate_count: length(candidates)}
    }
  end

  defp max_candidates do
    case Settings.get("intent.max_candidates") do
      {:ok, value} when is_integer(value) -> value
      _other -> 80
    end
  end
end
