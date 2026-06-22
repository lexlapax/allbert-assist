defmodule AllbertAssist.Actions.Intent.ShowDescriptor do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :intent_operator_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "intent_show_descriptor",
    description: "Show one resolved intent descriptor as a redacted operator DTO.",
    category: "intent",
    tags: ["intent", "descriptors", "operator", "read_only"],
    schema: [action: [type: :string, required: true]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Intent.OperatorSupport
  alias AllbertAssist.Actions.Operator.Support

  @impl true
  def run(params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      action = param(params, :action)
      descriptor = OperatorSupport.descriptor(action)
      status = if descriptor, do: :completed, else: :not_found
      message = OperatorSupport.render_descriptor(descriptor, action)

      {:ok,
       %{
         message: message,
         model_payload: "Resolved intent descriptor detail.",
         surface_payload: message,
         status: status,
         permission_decision: permission_decision,
         descriptor: descriptor,
         actions: [
           Support.action(name(), status, permission_decision, %{action_name: action})
         ]
       }}
    end)
  end

  defp param(params, key), do: Map.get(params, key, Map.get(params, Atom.to_string(key), ""))
end
