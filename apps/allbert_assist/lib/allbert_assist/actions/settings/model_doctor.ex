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
      scope: [type: :string, required: false],
      render_mode: [type: :string, required: false],
      surface: [type: :string, required: false],
      surface_policy_affordance: [type: :boolean, required: false]
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
  alias AllbertAssist.SurfacePolicy

  @impl true
  def run(params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      policy = SurfacePolicy.report_policy(name(), params, context)
      report = ModelRecommendations.diagnose(context, scope: scope(params))
      visible_report = bounded_report(report, policy)
      message = message(visible_report, length(report.rows), policy)

      {:ok,
       %{
         message: message,
         model_payload: "Model recommendation doctor.",
         surface_payload: message,
         status: :completed,
         permission_decision: permission_decision,
         model_doctor: visible_report,
         actions: [
           Support.action(name(), :completed, permission_decision, %{
             summary: report.summary,
             row_count: length(report.rows),
             rendered_count: length(visible_report.rows),
             render_mode: policy.render_mode,
             max_rows: policy.max_rows,
             surface_policy_source: policy.source
           })
         ]
       }}
    end)
  end

  defp message(report, total_count, %{render_mode: :operator_report}) do
    suffix =
      if length(report.rows) < total_count do
        "\n\nShowing #{length(report.rows)} of #{total_count} rows under surface policy."
      else
        ""
      end

    "#{ModelRecommendations.render(report)}#{suffix}"
  end

  defp message(report, total_count, %{render_mode: :assistant_summary}) do
    summary = report.summary

    "Model doctor checked #{total_count} recommendation rows: ok=#{summary["ok"]} " <>
      "missing=#{summary["missing"]} under-capable=#{summary["under-capable"]} " <>
      "not-pulled=#{summary["not-pulled"]} remote-egress-warning=#{summary["remote-egress-warning"]}. " <>
      "I can discuss model readiness safely here, but I won't dump the operator matrix in chat. " <>
      "Use `/models` in the TUI or `mix allbert.settings model-doctor` for the operator report."
  end

  defp bounded_report(report, policy),
    do: Map.update!(report, :rows, &Enum.take(&1, policy.max_rows))

  defp scope(params) do
    case Map.get(params, :scope, Map.get(params, "scope")) do
      value when value in ["intent", :intent] -> :intent
      _other -> :all
    end
  end
end
