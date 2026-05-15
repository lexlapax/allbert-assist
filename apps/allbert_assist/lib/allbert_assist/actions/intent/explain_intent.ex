defmodule AllbertAssist.Actions.Intent.ExplainIntent do
  @moduledoc false

  use Jido.Action,
    name: "explain_intent",
    description: "Explain the registry-aware intent decision for text without executing it.",
    category: "intent",
    tags: ["intent", "read_only", "internal"],
    schema: [
      text: [type: :string, required: true],
      active_app: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Intent.Engine
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(%{text: text} = params, context) when is_binary(text) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    request = request(params, context)

    with {:ok, decision} <- Engine.decide(request) do
      {:ok,
       %{
         message: message(decision),
         status: PermissionGate.response_status(permission_decision),
         decision: Decision.to_map(decision),
         intent_candidates: get_in(decision.trace_metadata, [:intent_candidates]),
         actions: [action(:completed, permission_decision, decision)]
       }}
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    {:ok,
     %{
       message: "Intent explanation requires text.",
       status: :denied,
       error: :missing_text,
       actions: [action(:denied, permission_decision, nil)]
     }}
  end

  defp request(params, context) do
    context
    |> Map.get(:request, %{})
    |> Map.merge(%{
      text: Map.fetch!(params, :text),
      active_app: Map.get(params, :active_app) || get_in(context, [:request, :active_app])
    })
  end

  defp message(decision) do
    candidates = get_in(decision.trace_metadata, [:intent_candidates]) || %{}
    selected = Map.get(candidates, :selected, %{})

    "Intent #{inspect(decision.intent)} selected #{Map.get(selected, :kind)}/#{Map.get(selected, :id)}."
  end

  defp action(status, permission_decision, decision) do
    %{
      name: "explain_intent",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      intent_metadata: intent_metadata(decision)
    }
  end

  defp intent_metadata(nil), do: %{error: :missing_text}

  defp intent_metadata(decision) do
    candidates = get_in(decision.trace_metadata, [:intent_candidates]) || %{}

    %{
      intent: decision.intent,
      selected_action: decision.selected_action,
      selected_skill: decision.selected_skill,
      active_app: decision.active_app,
      candidate_count: Map.get(candidates, :total, 0)
    }
  end
end
