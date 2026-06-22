defmodule AllbertAssist.Actions.Intent.EnableDescriptor do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :intent_descriptor_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "enable_intent_descriptor",
    description: "Remove a disabled descriptor override after the routing gate passes.",
    category: "intent",
    tags: ["intent", "descriptor", "operator", "write"],
    schema: [action: [type: :string, required: true]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      descriptor: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Intent.MutationSupport

  @impl true
  def run(%{action: action}, context) do
    MutationSupport.write_action(name(), context, fn permission_decision ->
      with {:ok, result} <- MutationSupport.enable(action) do
        MutationSupport.finish(name(), result, permission_decision, %{
          descriptor: Map.get(result, :descriptor),
          error: Map.get(result, :error)
        })
      end
    end)
  end
end
