defmodule AllbertAssist.Objectives.Runs.Worker.Agent do
  @moduledoc """
  Ephemeral Jido Agent definition for one clean DirectAnswer Objective child.

  The Adapter runs one pure `cmd/3` lifecycle inside a linked temporary task;
  it does not start an AgentServer or own a second queue. This agent owns no
  durable state, authority, prompt, or model policy. `AllbertAssist.Objectives`
  remains the durable system of record.
  """

  @dialyzer {:nowarn_function, __agent_metadata__: 0}
  @dialyzer {:nowarn_function, actions: 0}
  @dialyzer {:nowarn_function, signal_routes: 0}
  @dialyzer {:nowarn_function, validate: 2}

  use Jido.Agent,
    name: "allbert_objective_direct_answer_worker",
    description: "Run one clean DirectAnswer child through the registered Allbert action.",
    signal_routes: [
      {"allbert.objectives.worker.execute",
       AllbertAssist.Objectives.Runs.Worker.Commands.Execute},
      {"allbert.objectives.worker.review_and_revise",
       AllbertAssist.Objectives.Runs.Worker.Commands.ReviewAndRevise}
    ]
end
