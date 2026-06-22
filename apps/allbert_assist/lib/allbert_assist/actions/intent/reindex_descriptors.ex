defmodule AllbertAssist.Actions.Intent.ReindexDescriptors do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :intent_descriptor_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "reindex_intent_descriptors",
    description: "Rebuild the intent descriptor index.",
    category: "intent",
    tags: ["intent", "descriptor", "operator", "write"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      index: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Intent.MutationSupport

  @impl true
  def run(_params, context) do
    MutationSupport.write_action(name(), context, fn permission_decision ->
      with {:ok, result} <- MutationSupport.reindex() do
        MutationSupport.finish(name(), result, permission_decision, result.index)
      end
    end)
  end
end
