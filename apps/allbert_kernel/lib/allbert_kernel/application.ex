defmodule AllbertKernel.Application do
  @moduledoc "OTP application owner for the kernel Pack supervision epoch."

  use Application

  alias AllbertAssist.Kernel.Contract.Owner, as: ContractOwner
  alias AllbertAssist.Pack.Supervisor, as: PackSupervisor

  @impl true
  def start(_type, _args) do
    # The contract owner is a sibling of the Pack epoch rather than a child of
    # it. It is coupled to that epoch by the monitor it holds on the readiness
    # barrier — a Registry or Readiness restart kills the barrier and the owner
    # releases the binding — so it does not also need to share the restart
    # group, and keeping it out lets a test start an isolated Pack.Supervisor
    # without colliding on the one globally named owner.
    children = [
      ContractOwner,
      PackSupervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
  end
end
