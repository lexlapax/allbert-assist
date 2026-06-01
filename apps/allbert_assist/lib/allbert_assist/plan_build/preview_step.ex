defmodule AllbertAssist.PlanBuild.PreviewStep do
  @moduledoc """
  One advisory step row in a Plan Preview Contract packet.
  """

  defstruct [
    :ordinal,
    :id,
    :kind,
    :action_name,
    params_summary: %{},
    permission: :read_only,
    safety_floor: :allowed,
    resources_needed: [],
    estimated_cost: %{tokens: 0, dollars: 0.0, seconds: 1},
    confidence_tier: :green,
    confirmations_required: false,
    subagent_target: nil,
    failure_blast_radius: %{halts_at: nil, unreachable: []}
  ]

  @type t :: %__MODULE__{}
end
