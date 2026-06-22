defmodule AllbertAssist.Actions.Intent.Coverage do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :intent_operator_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "intent_coverage",
    description: "Show read-only intent descriptor coverage.",
    category: "intent",
    tags: ["intent", "coverage", "operator", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      coverage: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Intent.OperatorSupport
  alias AllbertAssist.Actions.Operator.Support

  @impl true
  def run(_params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      coverage = OperatorSupport.coverage()
      message = OperatorSupport.render_coverage(coverage)

      {:ok,
       %{
         message: message,
         model_payload: "Intent coverage report.",
         surface_payload: message,
         status: :completed,
         permission_decision: permission_decision,
         coverage: coverage,
         actions: [
           Support.action(name(), :completed, permission_decision, %{
             covered: coverage.covered,
             missing: length(coverage.missing)
           })
         ]
       }}
    end)
  end
end
