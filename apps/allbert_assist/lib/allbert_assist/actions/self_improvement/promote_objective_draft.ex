defmodule AllbertAssist.Actions.SelfImprovement.PromoteObjectiveDraft do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :objective_write,
    exposure: :internal,
    execution_mode: :objective_draft_promotion,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "promote_objective_draft",
    description: "Promote an inert objective draft into a v0.24 objective after confirmation.",
    category: "self_improvement",
    tags: ["self_improvement", "drafts", "promotion", "objective_write"],
    schema: [id: [type: :string, required: true]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      confirmation_id: [type: :string, required: false],
      draft: [type: :map, required: false],
      objective: [type: :map, required: false],
      result: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.SelfImprovement.PromotionAction
  alias AllbertAssist.Drafts.Promotion

  @impl true
  def run(params, context) do
    PromotionAction.run(params, context, %{
      module: __MODULE__,
      action_name: "promote_objective_draft",
      kind: "objective",
      permission: :objective_write,
      execution_mode: :objective_draft_promotion,
      promote: &Promotion.promote_objective/2
    })
  end
end
