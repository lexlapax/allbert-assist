defmodule AllbertAssist.Actions.Intent.ListReview do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :intent_operator_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "intent_list_review",
    description: "List learned intent descriptor proposals pending operator review.",
    category: "intent",
    tags: ["intent", "review", "operator", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      proposals: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Intent.OperatorSupport
  alias AllbertAssist.Actions.Operator.Support

  @impl true
  def run(_params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      proposals = OperatorSupport.review_proposals()
      message = OperatorSupport.render_review(proposals)

      {:ok,
       %{
         message: message,
         model_payload: "Intent learned-review proposal list.",
         surface_payload: message,
         status: :completed,
         permission_decision: permission_decision,
         proposals: proposals,
         actions: [
           Support.action(name(), :completed, permission_decision, %{count: length(proposals)})
         ]
       }}
    end)
  end
end
