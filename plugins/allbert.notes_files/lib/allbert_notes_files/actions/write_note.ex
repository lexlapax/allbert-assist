defmodule AllbertNotesFiles.Actions.WriteNote do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :notes_file_write,
    exposure: :agent,
    execution_mode: :notes_file_write,
    skill_backed?: true,
    confirmation: :required,
    resumable?: true,
    app_id: :notes_files,
    plugin_id: "allbert.notes_files",
    notes: "Writes local note files only after durable operator confirmation.",
    name: "write_note",
    description: "Write a local note under the configured notes root after approval.",
    category: "notes_files",
    tags: ["notes", "files", "write", "confirmation_required"],
    schema: [
      title: [type: :string, required: true],
      body: [type: :string, required: true],
      path: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertNotesFiles.{Actions, Notes}

  @permission :notes_file_write
  @action_name "write_note"

  def capability do
    Actions.capability(@permission,
      execution_mode: :notes_file_write,
      confirmation: :required,
      resumable?: true
    )
  end

  @impl true
  def run(params, context) when is_map(params) do
    permission_decision = Actions.authorize(@permission, context)

    with false <- permission_decision.decision == :denied,
         {:ok, request} <- Notes.prepare_write(params) do
      if approved_resume?(context) do
        execute_write(request, permission_decision, context)
      else
        create_confirmation(request, context, permission_decision)
      end
    else
      true -> Actions.denied(@action_name, @permission, permission_decision, :permission_denied)
      {:error, reason} -> invalid_request(reason, permission_decision)
    end
  end

  def run(_params, context) do
    permission_decision = Actions.authorize(@permission, context)
    invalid_request(:invalid_params, permission_decision)
  end

  defp execute_write(request, permission_decision, context) do
    case Notes.write_prepared(request) do
      {:ok, note} ->
        {:ok,
         %{
           message: "Wrote note #{note.relative_path}.",
           status: :completed,
           permission_decision: permission_decision,
           note: note,
           resource_refs: note.resource_refs,
           actions: [
             Actions.action(@action_name, :completed, @permission, permission_decision, %{
               target_resumed?: approved_resume?(context),
               relative_path: note.relative_path,
               resource_refs: note.resource_refs
             })
           ]
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: "Note write failed after approval: #{inspect(reason)}.",
           status: :failed,
           error: reason,
           permission_decision: permission_decision,
           note_write_request: request_summary(request),
           actions: [
             Actions.action(@action_name, :failed, @permission, permission_decision, %{
               error: reason,
               resource_refs: request.resource_refs
             })
           ]
         }}
    end
  end

  defp create_confirmation(request, context, permission_decision) do
    summary = request_summary(request)

    attrs = %{
      origin: Origin.from_context(context, @action_name),
      target_action: %{name: @action_name, module: inspect(__MODULE__)},
      target_permission: @permission,
      target_execution_mode: :notes_file_write,
      security_decision: permission_decision,
      source_signal_id: Map.get(context, :runner_requested_signal_id),
      source_trace_id: Map.get(context, :trace_id),
      runner_metadata: Map.get(context, :runner_metadata, %{}),
      params_summary: summary,
      resume_params_ref: resume_params(request)
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        {:ok,
         %{
           message:
             "Note write needs confirmation. Confirmation request: #{confirmation["id"]}. Nothing has written yet.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           note_write_request: summary,
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [
             Actions.action(@action_name, :needs_confirmation, @permission, permission_decision, %{
               confirmation_id: confirmation["id"],
               resource_refs: request.resource_refs
             })
           ]
         }}

      {:error, reason} ->
        Actions.denied(@action_name, @permission, permission_decision, reason)
    end
  end

  defp invalid_request(reason, permission_decision) do
    {:ok,
     %{
       message: "Note write request is invalid: #{inspect(reason)}.",
       status: :error,
       error: reason,
       permission_decision: permission_decision,
       actions: [
         Actions.action(@action_name, :error, @permission, permission_decision, %{error: reason})
       ]
     }}
  end

  defp request_summary(request) do
    request
    |> Map.take([:app_id, :title, :path, :relative_path, :resource_uri, :resource_refs])
    |> Map.put(:operation, :write_note)
  end

  defp resume_params(request) do
    request
    |> Map.take([:app_id, :title, :body, :path])
  end

  defp approved_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end
end
