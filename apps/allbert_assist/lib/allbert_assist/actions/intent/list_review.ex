defmodule AllbertAssist.Actions.Intent.ListReview do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :intent_operator_read,
    skill_backed?: false,
    confirmation: :not_required,
    name: "intent_list_review",
    description: "List learned intent descriptor proposals pending operator review.",
    category: "intent",
    tags: ["intent", "review", "operator", "read_only"],
    schema: [
      render_mode: [type: :string, required: false],
      surface: [type: :string, required: false],
      surface_policy_affordance: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      proposals: [type: {:list, :map}, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Actions.Intent.OperatorSupport
  alias AllbertAssist.Actions.Operator.Support
  alias AllbertAssist.SurfacePolicy

  @impl true
  def run(params, context) do
    Support.read_only(name(), context, fn permission_decision ->
      policy = SurfacePolicy.report_policy(name(), params, context)
      proposals = OperatorSupport.review_proposals()
      visible_proposals = bounded(proposals, policy)
      message = message(visible_proposals, length(proposals), policy)

      {:ok,
       %{
         message: message,
         model_payload: "Intent learned-review proposal list.",
         surface_payload: message,
         status: :completed,
         permission_decision: permission_decision,
         proposals: visible_proposals,
         actions: [
           Support.action(name(), :completed, permission_decision, %{
             count: length(proposals),
             rendered_count: length(visible_proposals),
             render_mode: policy.render_mode,
             max_rows: policy.max_rows,
             surface_policy_source: policy.source
           })
         ]
       }}
    end)
  end

  defp message([], _total_count, %{render_mode: :operator_report}),
    do: "no descriptors pending review"

  defp message(proposals, total_count, %{render_mode: :operator_report}) do
    suffix =
      if length(proposals) < total_count do
        "\n\nShowing #{length(proposals)} of #{total_count} rows under surface policy."
      else
        ""
      end

    "#{OperatorSupport.render_review(proposals)}#{suffix}"
  end

  defp message(_proposals, total_count, %{render_mode: :assistant_summary}) do
    "Intent review has #{total_count} learned descriptor proposals pending. I can " <>
      "summarize review status here, but I won't dump the operator proposal inventory " <>
      "in chat. Use `/intents` in the TUI or `mix allbert.intent review` for the operator report."
  end

  defp bounded(rows, policy), do: Enum.take(rows, policy.max_rows)
end
