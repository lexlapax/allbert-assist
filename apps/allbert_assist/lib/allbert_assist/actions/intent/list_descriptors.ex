defmodule AllbertAssist.Actions.Intent.ListDescriptors do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :intent_operator_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "intent_list_descriptors",
    description: "List resolved intent descriptors as a redacted operator DTO.",
    category: "intent",
    tags: ["intent", "descriptors", "operator", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      descriptors: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Intent.OperatorSupport
  alias AllbertAssist.Actions.Operator.Support

  @impl true
  def run(_params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      descriptors = OperatorSupport.descriptors()
      message = OperatorSupport.render_descriptors(descriptors)

      {:ok,
       %{
         message: message,
         model_payload: "Resolved intent descriptor list.",
         surface_payload: message,
         status: :completed,
         permission_decision: permission_decision,
         descriptors: descriptors,
         actions: [
           Support.action(name(), :completed, permission_decision, %{count: length(descriptors)})
         ]
       }}
    end)
  end
end
