defmodule AllbertAssist.Actions.Operator.Events do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :read_only,
    skill_backed?: false,
    confirmation: :not_required,
    name: "operator_events",
    description: "Show recent channel-event metadata for operator inspection.",
    category: "operator",
    tags: ["operator", "events", "read_only"],
    schema: [limit: [type: :integer, required: false]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      events: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Operator.Support
  alias AllbertAssist.Operator.Inspection

  @impl true
  def run(params, context) when is_map(params) do
    Support.read_only(name(), context, fn permission_decision ->
      report = Inspection.events(params)
      message = Inspection.render_events(report)

      {:ok,
       %{
         message: message,
         model_payload: "Operator channel-events report.",
         surface_payload: message,
         status: :completed,
         permission_decision: permission_decision,
         events: report,
         actions: [
           Support.action(name(), :completed, permission_decision, %{count: report.count})
         ]
       }}
    end)
  end
end
