defmodule AllbertAssist.Actions.Session.SetActiveApp do
  @moduledoc false

  use Jido.Action,
    name: "set_active_app",
    description: "Set the active app for a volatile local session.",
    category: "session",
    tags: ["session", "settings", "write"],
    schema: [
      user_id: [type: :string, required: true],
      session_id: [type: :string, required: true],
      app_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Session

  @impl true
  def run(%{user_id: user_id, session_id: session_id} = params, context) do
    app_id = Map.get(params, :app_id)
    permission_decision = PermissionGate.authorize(:settings_write, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, entry} <- Session.set_active_app(user_id, session_id, app_id) do
      summary = Session.summary(entry)

      {:ok,
       %{
         message:
           "Set active app for #{summary.user_id}/#{summary.session_id} to #{Session.active_app_label(summary.active_app)}.",
         status: :completed,
         session: summary,
         actions: [action(:completed, permission_decision, summary)]
       }}
    else
      false -> denied(user_id, session_id, permission_decision, :permission_denied)
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
       message: "I could not set active app: #{inspect(reason)}",
       status: :denied,
       error: reason,
       actions: [action(:denied, permission_decision, error_summary(user_id, session_id, reason))]
     }}
  end

  defp action(status, permission_decision, session_metadata) do
    %{
      name: "set_active_app",
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
