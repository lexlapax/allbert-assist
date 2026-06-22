defmodule AllbertAssist.Actions.Operator.Channels do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :read_only,
    skill_backed?: false,
    confirmation: :not_required,
    name: "operator_channels",
    description: "Show read-only channel inventory for operator inspection.",
    category: "operator",
    tags: ["operator", "channels", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      channels: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Operator.Support
  alias AllbertAssist.Operator.Inspection

  @impl true
  def run(_params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      report = Inspection.channels(context)
      message = Inspection.render_channels(report)

      {:ok,
       %{
         message: message,
         model_payload: "Operator channel inventory.",
         surface_payload: message,
         status: :completed,
         permission_decision: permission_decision,
         channels: report,
         actions: [
           Support.action(name(), :completed, permission_decision, %{count: report.count})
         ]
       }}
    end)
  end
end
