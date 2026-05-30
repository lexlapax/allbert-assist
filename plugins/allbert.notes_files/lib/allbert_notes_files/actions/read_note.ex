defmodule AllbertNotesFiles.Actions.ReadNote do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :read_only,
    skill_backed?: true,
    confirmation: :not_required,
    app_id: :notes_files,
    plugin_id: "allbert.notes_files",
    name: "read_note",
    description: "Read one bounded local note under the configured notes root.",
    category: "notes_files",
    tags: ["notes", "files", "read_only"],
    schema: [
      path: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertNotesFiles.{Actions, Notes}

  @permission :read_only
  @action_name "read_note"

  def capability, do: Actions.capability(@permission)

  @impl true
  def run(params, context) do
    permission_decision = Actions.authorize(@permission, context)
    path = Actions.field(params, :path)

    cond do
      not Actions.allowed?(permission_decision) ->
        Actions.denied(@action_name, @permission, permission_decision, :permission_denied)

      is_nil(path) or String.trim(to_string(path)) == "" ->
        Actions.denied(@action_name, @permission, permission_decision, :missing_path)

      true ->
        read_note(path, permission_decision)
    end
  end

  defp read_note(path, permission_decision) do
    case Notes.read(path) do
      {:ok, note} ->
        {:ok,
         %{
           message: "Read note #{note.relative_path}.",
           status: :completed,
           permission_decision: permission_decision,
           note: note,
           resource_refs: note.resource_refs,
           actions: [
             Actions.action(@action_name, :completed, @permission, permission_decision, %{
               relative_path: note.relative_path,
               resource_refs: note.resource_refs
             })
           ]
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: "Note could not be read: #{inspect(reason)}.",
           status: :error,
           error: reason,
           permission_decision: permission_decision,
           actions: [
             Actions.action(@action_name, :error, @permission, permission_decision, %{
               error: reason
             })
           ]
         }}
    end
  end
end
