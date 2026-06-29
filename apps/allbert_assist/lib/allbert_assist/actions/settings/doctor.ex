defmodule AllbertAssist.Actions.Settings.Doctor do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :settings_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "settings_doctor",
    description: "Show Settings Central version-contract readiness and diagnostics.",
    category: "settings",
    tags: ["settings", "version_contract", "doctor", "read_only", "operator"],
    schema: [
      render_mode: [type: :string, required: false],
      surface: [type: :string, required: false],
      surface_policy_affordance: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      settings_version: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Operator.Support
  alias AllbertAssist.Settings.VersionContract
  alias AllbertAssist.SurfacePolicy

  @impl true
  def run(params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      policy = SurfacePolicy.report_policy(name(), params, context)
      report = VersionContract.status_from_store()
      visible_report = bounded_report(report, policy)
      message = message(visible_report, policy)

      {:ok,
       %{
         message: message,
         surface_payload: message,
         status: :completed,
         permission_decision: permission_decision,
         settings_version: visible_report,
         actions: [
           Support.action(name(), :completed, permission_decision, %{
             settings_version_status: report.status,
             counts: report.counts,
             row_count: length(report.inventory),
             rendered_count: length(visible_report.inventory),
             render_mode: policy.render_mode,
             max_rows: policy.max_rows,
             surface_policy_source: policy.source
           })
         ]
       }}
    end)
  end

  defp message(report, %{render_mode: :operator_report}) do
    VersionContract.render(report)
  end

  defp message(report, %{render_mode: :assistant_summary}) do
    counts = report.counts

    "Settings doctor checked #{report.total_fragments} fragments: status=#{report.status} " <>
      "current=#{counts.current} pending=#{counts.pending} forward=#{counts.forward} " <>
      "invalid=#{counts.invalid}. Use `mix allbert.settings doctor` for the operator report."
  end

  defp bounded_report(report, %{max_rows: max_rows}) do
    Map.update!(report, :inventory, &Enum.take(&1, max_rows))
  end
end
