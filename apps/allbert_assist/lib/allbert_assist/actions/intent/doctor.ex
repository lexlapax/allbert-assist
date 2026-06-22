defmodule AllbertAssist.Actions.Intent.Doctor do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :intent_operator_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "intent_doctor",
    description: "Show read-only intent router, coverage, and eval-baseline status.",
    category: "intent",
    tags: ["intent", "operator", "doctor", "read_only"],
    schema: [],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      intent_doctor: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Intent.OperatorSupport
  alias AllbertAssist.Actions.Operator.Support
  alias AllbertAssist.Intent.Router.Doctor, as: RouterDoctor
  alias AllbertAssist.Settings.ModelRecommendations

  @impl true
  def run(_params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      {:ok, router} = RouterDoctor.diagnose()
      coverage = OperatorSupport.coverage()
      baseline = OperatorSupport.baseline_summary() |> public_baseline()
      model_report = ModelRecommendations.diagnose(context, scope: :intent)

      message =
        [
          OperatorSupport.render_doctor(router, coverage, baseline),
          ModelRecommendations.render(model_report)
        ]
        |> Enum.join("\n")

      {:ok,
       %{
         message: message,
         model_payload: "Intent router doctor.",
         surface_payload: message,
         status: :completed,
         permission_decision: permission_decision,
         intent_doctor: %{
           router: router,
           coverage: coverage,
           baseline: baseline,
           model_doctor: model_report
         },
         actions: [
           Support.action(name(), :completed, permission_decision, %{
             report: %{router_status: router.status, coverage: coverage.routable}
           })
         ]
       }}
    end)
  end

  defp public_baseline(nil), do: nil
  defp public_baseline(baseline), do: Map.drop(baseline, [:raw])
end
