defmodule AllbertAssist.Intent.FanoutManager.Agent do
  @moduledoc """
  Ephemeral Jido Agent for one bounded conversational manager decision.

  `FanoutManager` owns the public Interface and deterministic policy compiler.
  This pure Agent validates the assess/adjudicate lifecycle around one normal
  qualified model call and, only after deterministic rejection, one optional
  repair call. The adjudication command is local and model-off. It has no
  AgentServer, durable state, registered capability action, authority, or
  execution loop.
  """

  @dialyzer {:nowarn_function, __agent_metadata__: 0}
  @dialyzer {:nowarn_function, actions: 0}
  @dialyzer {:nowarn_function, signal_routes: 0}
  @dialyzer {:nowarn_function, validate: 2}

  use Jido.Agent,
    name: "allbert_conversation_fanout_manager",
    description: "Assess and adjudicate one bounded advisory fan-out candidate.",
    schema: [
      phase: [type: {:in, [:ready, :assessed, :adjudicated]}, default: :ready],
      phases: [type: {:list, :atom}, default: []],
      attempts: [type: :non_neg_integer, default: 0],
      last_result: [type: :any, default: nil]
    ],
    signal_routes: [
      {"allbert.intent.fanout.assess", AllbertAssist.Intent.FanoutManager.Commands.Assess},
      {"allbert.intent.fanout.adjudicate", AllbertAssist.Intent.FanoutManager.Commands.Adjudicate}
    ]
end
