defmodule AllbertAssist.Actions.Intent.OptimizeDescriptors do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :settings_write,
    exposure: :internal,
    execution_mode: :intent_descriptor_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "optimize_intent_descriptors",
    description: "Generate missing intent descriptor candidates through the gated operator path.",
    category: "intent",
    tags: ["intent", "descriptor", "operator", "write"],
    schema: [
      strategy: [type: :string, required: false],
      heuristic: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      result: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Intent.MutationSupport

  @impl true
  def run(params, context) do
    MutationSupport.write_action(name(), context, fn permission_decision ->
      with {:ok, result} <- MutationSupport.optimize(params) do
        MutationSupport.finish(name(), result, permission_decision, %{
          generated: length(result.result.generated),
          reviewed: length(result.result.reviewed),
          rejected: length(Map.get(result.result, :rejected, []))
        })
      end
    end)
  end
end
