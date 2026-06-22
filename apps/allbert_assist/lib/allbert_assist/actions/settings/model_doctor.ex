defmodule AllbertAssist.Actions.Settings.ModelDoctor do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "model_doctor",
    description: "Show per-purpose model recommendations versus current Settings Central config.",
    category: "settings",
    tags: ["settings", "models", "doctor", "read_only", "operator"],
    schema: [
      scope: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      model_doctor: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Operator.Support
  alias AllbertAssist.Settings.ModelRecommendations

  @impl true
  def run(params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      report = ModelRecommendations.diagnose(context, scope: scope(params))
      message = ModelRecommendations.render(report)

      {:ok,
       %{
         message: message,
         model_payload: "Model recommendation doctor.",
         surface_payload: message,
         status: :completed,
         permission_decision: permission_decision,
         model_doctor: report,
         actions: [
           Support.action(name(), :completed, permission_decision, %{
             summary: report.summary,
             row_count: length(report.rows)
           })
         ]
       }}
    end)
  end

  defp scope(params) do
    case Map.get(params, :scope, Map.get(params, "scope")) do
      value when value in ["intent", :intent] -> :intent
      _other -> :all
    end
  end
end
