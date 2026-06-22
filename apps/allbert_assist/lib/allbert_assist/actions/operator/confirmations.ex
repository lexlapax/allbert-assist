defmodule AllbertAssist.Actions.Operator.Confirmations do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :confirmation_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "operator_confirmations",
    description: "Show read-only confirmation requests for operator inspection.",
    category: "operator",
    tags: ["operator", "confirmations", "read_only"],
    schema: [status: [type: :string, required: false]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      confirmations: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Operator.Support
  alias AllbertAssist.Operator.Inspection

  @impl true
  def run(params, context) when is_map(params) do
    Support.read_only(name(), context, fn permission_decision ->
      report = Inspection.confirmations(params)
      message = Inspection.render_confirmations(report)

      {:ok,
       %{
         message: message,
         model_payload: "Operator confirmations report.",
         surface_payload: message,
         status: :completed,
         permission_decision: permission_decision,
         confirmations: report,
         actions: [
           Support.action(name(), :completed, permission_decision, %{count: report.count})
         ]
       }}
    end)
  end
end
