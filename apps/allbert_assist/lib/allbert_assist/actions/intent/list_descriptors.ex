defmodule AllbertAssist.Actions.Intent.ListDescriptors do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :intent_operator_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "intent_list_descriptors",
    description: "List resolved intent descriptors as a redacted operator DTO.",
    category: "intent",
    tags: ["intent", "descriptors", "operator", "read_only"],
    schema: [
      render_mode: [type: :string, required: false],
      surface: [type: :string, required: false],
      surface_policy_affordance: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      descriptors: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Intent.OperatorSupport
  alias AllbertAssist.Actions.Operator.Support
  alias AllbertAssist.SurfacePolicy

  @impl true
  def run(params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      policy = SurfacePolicy.report_policy(name(), params, context)
      descriptors = OperatorSupport.descriptors()
      visible_descriptors = bounded(descriptors, policy)
      message = message(visible_descriptors, length(descriptors), policy)

      {:ok,
       %{
         message: message,
         model_payload: "Resolved intent descriptor list.",
         surface_payload: message,
         status: :completed,
         permission_decision: permission_decision,
         descriptors: visible_descriptors,
         actions: [
           Support.action(name(), :completed, permission_decision, %{
             count: length(descriptors),
             rendered_count: length(visible_descriptors),
             render_mode: policy.render_mode,
             max_rows: policy.max_rows,
             surface_policy_source: policy.source
           })
         ]
       }}
    end)
  end

  defp message([], _total_count, %{render_mode: :operator_report}), do: "no resolved descriptors"

  defp message(descriptors, total_count, %{render_mode: :operator_report}) do
    suffix =
      if length(descriptors) < total_count do
        "\n\nShowing #{length(descriptors)} of #{total_count} rows under surface policy."
      else
        ""
      end

    "#{OperatorSupport.render_descriptors(descriptors)}#{suffix}"
  end

  defp message(_descriptors, total_count, %{render_mode: :assistant_summary}) do
    "Intent registry has #{total_count} resolved descriptors. I can summarize routing " <>
      "coverage here, but I won't dump the operator descriptor inventory in chat. " <>
      "Use `/intents` in the TUI or `mix allbert.intent list` for the operator report."
  end

  defp bounded(rows, policy), do: Enum.take(rows, policy.max_rows)
end
