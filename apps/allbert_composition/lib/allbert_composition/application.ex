defmodule AllbertComposition.Application do
  @moduledoc "OTP owner for the composition coordinator."

  use Application

  @impl true
  def start(_type, _args) do
    children = [AllbertAssist.Pack.CompositionCoordinator]
    Supervisor.start_link(children, strategy: :one_for_one, name: AllbertComposition.Supervisor)
  end
end
