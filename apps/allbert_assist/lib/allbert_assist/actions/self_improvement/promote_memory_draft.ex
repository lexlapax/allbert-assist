defmodule AllbertAssist.Actions.SelfImprovement.PromoteMemoryDraft do
  @moduledoc false

  use AllbertAssist.Action,
    registry_order: 89,
    permission: :memory_write,
    exposure: :internal,
    execution_mode: :memory_promotion,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "promote_memory_draft",
    description: "Promote an inert self-improvement memory draft after confirmation.",
    category: "self_improvement",
    tags: ["self_improvement", "drafts", "promotion", "memory_write"],
    schema: [
      id: [type: :string, required: true],
      draft_digest: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      confirmation_id: [type: :string, required: false],
      draft: [type: :map, required: false],
      result: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.SelfImprovement.PromotionAction
  alias AllbertAssist.Drafts.Promotion

  @impl true
  def run(params, context) do
    PromotionAction.run(params, context, %{
      module: __MODULE__,
      action_name: "promote_memory_draft",
      kind: "memory",
      permission: :memory_write,
      execution_mode: :memory_promotion,
      bind_resume_params: &Promotion.memory_draft_binding/1,
      promote: fn id, resume_params, promotion_context ->
        digest = Map.get(resume_params, :draft_digest, Map.get(resume_params, "draft_digest"))
        Promotion.promote_memory(id, digest, promotion_context)
      end
    })
  end
end
