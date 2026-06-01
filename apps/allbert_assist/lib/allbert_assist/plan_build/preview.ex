defmodule AllbertAssist.PlanBuild.Preview do
  @moduledoc """
  Advisory Plan Preview Contract packet for v0.44 Plan/Build mode.
  """

  alias AllbertAssist.PlanBuild.PreviewStep

  @enforce_keys [:workflow_id, :workflow_version, :objective_title, :step_count, :steps]
  defstruct [
    :workflow_id,
    :workflow_version,
    resolved_inputs: %{},
    objective_title: nil,
    step_count: 0,
    steps: [],
    authority_gates: [],
    warnings: []
  ]

  @type t :: %__MODULE__{
          workflow_id: String.t(),
          workflow_version: pos_integer(),
          resolved_inputs: map(),
          objective_title: String.t(),
          step_count: non_neg_integer(),
          steps: [PreviewStep.t()],
          authority_gates: [map()],
          warnings: [String.t()]
        }
end
