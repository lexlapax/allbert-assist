defmodule AllbertNotesFiles.Actions.SearchNotes do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :read_only,
    skill_backed?: true,
    confirmation: :not_required,
    app_id: :notes_files,
    plugin_id: "allbert.notes_files",
    name: "search_notes",
    description: "Search bounded local notes under the configured notes root.",
    category: "notes_files",
    tags: ["notes", "files", "read_only"],
    schema: [
      query: [type: :string, required: false],
      limit: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertNotesFiles.{Actions, Notes}

  @permission :read_only
  @action_name "search_notes"

  def capability, do: Actions.capability(@permission)

  @impl true
  def run(params, context) do
    permission_decision = Actions.authorize(@permission, context)

    if Actions.allowed?(permission_decision) do
      query = Actions.field(params, :query, "")
      limit = params |> Actions.field(:limit, Notes.max_results()) |> Actions.positive_limit(Notes.max_results(), 100)

      {:ok, notes} = Notes.search(query, limit: limit)
      root_ref = Notes.root_ref()

      {:ok,
       %{
         message: "Found #{length(notes)} note(s).",
         status: :completed,
         permission_decision: permission_decision,
         notes: notes,
         resource_refs: [root_ref],
         actions: [
           Actions.action(@action_name, :completed, @permission, permission_decision, %{
             returned: length(notes),
             resource_refs: [root_ref]
           })
         ]
       }}
    else
      Actions.denied(@action_name, @permission, permission_decision, :permission_denied)
    end
  end
end
