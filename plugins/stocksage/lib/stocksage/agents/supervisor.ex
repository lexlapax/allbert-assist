defmodule StockSage.Agents.Supervisor do
  @moduledoc """
  Supervisor for StockSage native coordinator and specialist agents.

  The child processes are plugin-owned OTP children and register themselves
  with `AllbertAssist.Objectives.AgentRegistry` after their Jido AgentServer
  starts. Registration does not grant authority; execution still enters
  through registered actions and the objective delegate boundary.
  """

  use Supervisor

  alias StockSage.Agents

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [StockSage.Agents.NativeCoordinator | Agents.modules()]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
