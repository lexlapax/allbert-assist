defmodule AllbertAssist.Actions.Security.Review do
  @moduledoc """
  Read-only recent security review action for operator surfaces.
  """

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :security_status,
    skill_backed?: false,
    confirmation: :not_required,
    name: "security_review",
    description: "Review recent Security Central decisions and emergency disable switches.",
    category: "security",
    tags: ["security", "review", "read_only"],
    schema: [limit: [type: :integer, required: false]],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      permission_decision: [type: :map, required: true],
      security_review: [type: :map, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Security.Review, as: SecurityReview

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    review = SecurityReview.recent(params)

    {:ok,
     %{
       message: message(review),
       status: PermissionGate.response_status(permission_decision),
       permission_decision: permission_decision,
       security_review: review,
       actions: [
         %{
           name: "security_review",
           status: :completed,
           permission: :read_only,
           permission_decision: permission_decision,
           security_metadata: %{
             confirmations: length(review.confirmations),
             denials: length(review.denials),
             imports: length(review.imports),
             external_calls: length(review.external_calls),
             redaction_incidents: length(review.redaction_incidents)
           }
         }
       ]
     }}
  end

  defp message(review) do
    """
    Security review:
    Confirmations: #{length(review.confirmations)}
    Denials: #{length(review.denials)}
    Imports: #{length(review.imports)}
    External calls: #{length(review.external_calls)}
    Redaction incidents: #{length(review.redaction_incidents)}
    Emergency switches: #{length(review.emergency_switches)}
    """
    |> String.trim()
  end
end
