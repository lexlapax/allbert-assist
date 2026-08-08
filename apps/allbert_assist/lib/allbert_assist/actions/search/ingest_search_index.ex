defmodule AllbertAssist.Actions.Search.IngestSearchIndex do
  @moduledoc "Run one bounded Search projection ingestion/reconciliation pass."

  use AllbertAssist.Action,
    registry_order: 62,
    permission: :search_manage,
    exposure: :internal,
    execution_mode: :search_manage,
    skill_backed?: false,
    confirmation: :not_required,
    resumable?: true,
    retry_safety: :safe,
    name: "ingest_search_index",
    description: "Ingest bounded canonical conversation changes into Search.",
    category: "search",
    tags: ["search", "projection", "ingest", "managed-job"],
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
    do: ManageProjection.run(:ingest, "ingest_search_index", params, context)
end
