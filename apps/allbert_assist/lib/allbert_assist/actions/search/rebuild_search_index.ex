defmodule AllbertAssist.Actions.Search.RebuildSearchIndex do
  @moduledoc "Build, verify, and promote the complete derived Search projection."

  use AllbertAssist.Action,
    permission: :search_manage,
    exposure: :internal,
    execution_mode: :search_manage,
    skill_backed?: false,
    confirmation: :not_required,
    resumable?: true,
    retry_safety: :safe,
    name: "rebuild_search_index",
    description: "Build, verify, and promote a complete Search projection generation.",
    category: "search",
    tags: ["search", "projection", "rebuild", "managed-job"],
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
    do: ManageProjection.run(:rebuild, "rebuild_search_index", params, context)
end
