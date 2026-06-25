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
    schema: [
      render_mode: [type: :string, required: false],
      surface: [type: :string, required: false],
      surface_policy_affordance: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      coverage: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Intent.OperatorSupport
  alias AllbertAssist.Actions.Operator.Support
  alias AllbertAssist.SurfacePolicy

  @impl true
  def run(params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      policy = SurfacePolicy.report_policy(name(), params, context)
      coverage = OperatorSupport.coverage()
      message = message(coverage, policy)

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
             missing: length(coverage.missing),
             render_mode: policy.render_mode,
             max_rows: policy.max_rows,
             surface_policy_source: policy.source
           })
         ]
       }}
    end)
  end

  defp message(coverage, %{render_mode: :operator_report}),
    do: OperatorSupport.render_coverage(coverage)

  defp message(coverage, %{render_mode: :assistant_summary}) do
    OperatorSupport.render_coverage(coverage) <>
      ". I can discuss routing coverage safely here; raw descriptor inventories stay behind " <>
      "the operator report affordance."
  end
end
