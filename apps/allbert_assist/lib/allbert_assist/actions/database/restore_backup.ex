defmodule AllbertAssist.Actions.Database.RestoreBackup do
  @moduledoc """
  Restore the configured SQLite database from a backup-before-migrate copy.

  This overwrites the live database file, so it is confirmation-gated and never
  accepts an arbitrary destination path.
  """

  use AllbertAssist.Action,
    permission: :command_execute,
    exposure: :internal,
    execution_mode: :database_restore,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "restore_database_backup",
    description: "Restore the Allbert database from a backup-before-migrate copy.",
    category: "database",
    tags: ["database", "restore", "command_execute", "confirmation"],
    schema: [
      backup: [type: :string, required: false],
      dry_run: [type: :boolean, required: false],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Support.ConfirmationRequest
  alias AllbertAssist.Database
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:command_execute, context)
    backup = Map.get(params, :backup, "latest")

    cond do
      Map.get(params, :dry_run, false) ->
        preview(backup, permission_decision)

      not PermissionGate.allowed?(permission_decision) and not approval_resume?(context) ->
        request_or_deny(backup, permission_decision, context)

      true ->
        restore(backup, permission_decision)
    end
  end

  defp preview(backup, permission_decision) do
    {:ok,
     %{
       message: "Would restore Allbert database from #{backup}.",
       status: :completed,
       permission_decision: permission_decision,
       actions: [action(:completed, permission_decision, %{backup: backup, executed: false})]
     }}
  end

  defp request_or_deny(backup, permission_decision, context) do
    attrs = %{
      target_action: %{name: name(), module: inspect(__MODULE__)},
      target_permission: :command_execute,
      target_execution_mode: :database_restore,
      params_summary: %{backup: backup},
      resume_params_ref: %{backup: backup}
    }

    case ConfirmationRequest.resolve(permission_decision, attrs, context) do
      {:needs_confirmation, confirmation} ->
        {:ok,
         %{
           message:
             "Database restore is ready for approval. Confirmation request: " <>
               "#{confirmation["id"]}. Nothing was restored.",
           status: :needs_confirmation,
           permission_decision: permission_decision,
           confirmation: confirmation,
           confirmation_id: confirmation["id"],
           actions: [
             action(:needs_confirmation, permission_decision, %{
               backup: backup,
               executed: false,
               confirmation_id: confirmation["id"]
             })
           ]
         }}

      _denied ->
        denied(permission_decision, backup)
    end
  end

  defp restore(backup, permission_decision) do
    case Database.restore_from_backup(backup) do
      {:ok, %{backup: backup_path, database: database}} ->
        {:ok,
         %{
           message: "Restored Allbert database from #{Path.basename(backup_path)}.",
           status: :completed,
           permission_decision: permission_decision,
           actions: [
             action(:completed, permission_decision, %{
               backup: backup_path,
               database: database,
               executed: true
             })
           ]
         }}

      {:error, reason} ->
        {:ok,
         %{
           message: "Database restore failed: #{inspect(reason)}",
           status: :error,
           permission_decision: permission_decision,
           actions: [
             action(:error, permission_decision, %{backup: backup, error: inspect(reason)})
           ]
         }}
    end
  end

  defp denied(permission_decision, backup) do
    {:ok,
     %{
       message: permission_decision.reason,
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       actions: [action(:denied, permission_decision, %{backup: backup, executed: false})]
     }}
  end

  defp approval_resume?(context) do
    get_in(context, [:confirmation, :approved?]) == true ||
      get_in(context, ["confirmation", "approved?"]) == true
  end

  defp action(status, permission_decision, metadata) do
    Map.merge(
      %{
        name: name(),
        status: status,
        permission: :command_execute,
        permission_decision: permission_decision
      },
      metadata
    )
  end
end
