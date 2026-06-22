defmodule AllbertAssist.Actions.Operator.Status do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :security_status,
    skill_backed?: false,
    confirmation: :not_required,
    name: "operator_status",
    description: "Show read-only operator runtime status.",
    category: "operator",
    tags: ["operator", "status", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      operator_status: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Operator.Support
  alias AllbertAssist.Operator.Inspection

  @impl true
  def run(_params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      report = Inspection.status(context)
      message = Inspection.render_status(report)

      {:ok,
       %{
         message: message,
         model_payload: "Operator status report.",
         surface_payload: message,
         status: :completed,
         permission_decision: permission_decision,
         operator_status: report,
         actions: [
           Support.action(name(), :completed, permission_decision, %{
             report: %{node: report.node, channel: report.channel}
           })
         ]
       }}
    end)
  end
end
