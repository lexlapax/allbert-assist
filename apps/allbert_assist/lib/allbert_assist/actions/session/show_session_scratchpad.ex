defmodule AllbertAssist.Actions.Session.ShowSessionScratchpad do
  @moduledoc false

  use Jido.Action,
    name: "show_session_scratchpad",
    description: "Show trace-safe volatile session scratchpad metadata.",
    category: "session",
    tags: ["session", "read_only"],
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
    permission_decision = PermissionGate.authorize(:read_only, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, entry} <- Session.get(user_id, session_id) do
      summary = Session.summary(entry)

      {:ok,
       %{
         message:
           "Session #{summary.user_id}/#{summary.session_id} active_app=#{Session.active_app_label(summary.active_app)}.",
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
    permission_decision = PermissionGate.authorize(:read_only, context)
    denied(nil, nil, permission_decision, :invalid_params)
  end

  defp denied(user_id, session_id, permission_decision, reason) do
    {:ok,
     %{
       message: "I could not show session scratchpad: #{inspect(reason)}",
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
      name: "show_session_scratchpad",
      status: status,
      permission: :read_only,
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
