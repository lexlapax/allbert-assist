defmodule AllbertAssist.Actions.Integrations.OpenCalendarPanel do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :read_only,
    skill_backed?: false,
    confirmation: :not_required,
    app_id: :allbert,
    name: "open_calendar_panel",
    description: "Open the MCP-backed calendar workspace panel.",
    category: "integrations",
    tags: ["calendar", "agenda", "workspace", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      destination: [type: :string, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate

  @action_name "open_calendar_panel"
  @destination "workspace:calendar"

  @impl true
  def run(_params, context), do: respond(context)

  defp respond(context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    if PermissionGate.allowed?(permission_decision) do
      {:ok,
       %{
         message: "Open the Calendar workspace panel.",
         status: :completed,
         destination: @destination,
         actions: [action(:completed, permission_decision)]
       }}
    else
      {:ok,
       %{
         message: "Calendar panel handoff was denied.",
         status: PermissionGate.response_status(permission_decision),
         destination: @destination,
         actions: [action(:denied, permission_decision)]
       }}
    end
  end

  defp action(status, permission_decision) do
    %{
      name: @action_name,
      status: status,
      permission: :read_only,
      permission_decision: permission_decision,
      app_id: :allbert,
      destination: @destination
    }
  end
end
