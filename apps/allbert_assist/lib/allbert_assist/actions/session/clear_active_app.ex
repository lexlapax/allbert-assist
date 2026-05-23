defmodule AllbertAssist.Actions.Session.ClearActiveApp do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :settings_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "clear_active_app",
    description: "Clear the active app for an existing volatile local session.",
    category: "session",
    tags: ["session", "settings", "write"],
    schema: [
      user_id: [type: :string, required: true],
      session_id: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Session

  @impl true
  def run(%{user_id: user_id, session_id: session_id}, context) do
    permission_decision = PermissionGate.authorize(:settings_write, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, entry} <- Session.clear_active_app(user_id, session_id) do
      summary = Session.summary(entry)

      {:ok,
       %{
         message: "Cleared active app for #{summary.user_id}/#{summary.session_id}.",
         status: :completed,
         session: summary,
         actions: [action(:completed, permission_decision, summary)]
       }}
    else
      false -> denied(user_id, session_id, permission_decision, :permission_denied)
      {:error, :not_found} -> not_found(user_id, session_id, permission_decision)
      {:error, reason} -> denied(user_id, session_id, permission_decision, reason)
    end
  end

  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:settings_write, context)
    denied(nil, nil, permission_decision, :invalid_params)
  end

  defp denied(user_id, session_id, permission_decision, reason) do
    {:ok,
     %{
       message: "I could not clear active app: #{inspect(reason)}",
       status: :denied,
       error: reason,
       actions: [action(:denied, permission_decision, error_summary(user_id, session_id, reason))]
     }}
  end

  defp not_found(user_id, session_id, permission_decision) do
    {:ok,
     %{
       message: "Session #{user_id}/#{session_id} was not found.",
       status: :not_found,
       error: :not_found,
       actions: [
         action(:not_found, permission_decision, error_summary(user_id, session_id, :not_found))
       ]
     }}
  end

  defp action(status, permission_decision, session_metadata) do
    %{
      name: "clear_active_app",
      status: status,
      permission: :settings_write,
      permission_decision: permission_decision,
      session_metadata: session_metadata
    }
  end

  defp error_summary(user_id, session_id, reason) do
    %{
      user_id: user_id,
      session_id: session_id,
      error: reason
    }
  end
end
