defmodule AllbertAssist.Actions.Search.MaintainSearchIndex do
  @moduledoc "Run one bounded Search integrity, merge, and prune pass."

  use AllbertAssist.Action,
    permission: :search_manage,
    exposure: :internal,
    execution_mode: :search_manage,
    skill_backed?: false,
    confirmation: :not_required,
    resumable?: true,
    retry_safety: :safe,
    name: "maintain_search_index",
    description: "Verify and maintain the current Search projection generation.",
    category: "search",
    tags: ["search", "projection", "maintenance", "managed-job"],
    schema: [user_id: [type: :string, required: false]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      result: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Search.ManageProjection

  @impl true
  def run(params, context),
    do: ManageProjection.run(:maintain, "maintain_search_index", params, context)
end
