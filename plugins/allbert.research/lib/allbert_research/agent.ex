defmodule AllbertResearch.Agent do
  @moduledoc """
  Local v0.46 research/summarize delegate agent.

  This process is a Jido signal router. It is not an Allbert action and does
  not grant browser authority; its commands orchestrate existing browser
  actions through `AllbertAssist.Actions.Runner.run/3`.
  """

  use Jido.Agent,
    name: "allbert_research_specialist",
    description: "Delegated browser research and summarization specialist.",
    signal_routes: [
      {"allbert.objectives.delegate.research", AllbertResearch.Commands.Research},
      {"allbert.objectives.delegate.summarize_url", AllbertResearch.Commands.SummarizeUrl}
    ]

  @spec agent_id() :: String.t()
  def agent_id, do: AllbertResearch.Runtime.agent_id()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    AllbertResearch.Runtime.start_link(__MODULE__, opts)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    AllbertResearch.Runtime.child_spec(__MODULE__, opts)
  end

  @spec command_modules() :: [module()]
  def command_modules do
    [
      AllbertResearch.Commands.Research,
      AllbertResearch.Commands.SummarizeUrl
    ]
  end
end
