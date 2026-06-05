defmodule AllbertResearch.Supervisor do
  @moduledoc """
  Plugin-owned supervision tree for the v0.46 research specialist.

  The research specialist is a local Jido agent registered in
  `AllbertAssist.Objectives.AgentRegistry`. It owns no durable state and adds no
  action authority; every effectful browser operation still crosses
  `AllbertAssist.Actions.Runner.run/3`.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {AllbertResearch.Agent, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
