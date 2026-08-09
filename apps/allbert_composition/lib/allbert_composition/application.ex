defmodule AllbertComposition.Application do
  @moduledoc "OTP owner for the composition coordinator."

  use Application

  # ADR 0098 makes a controlled restart the coordinator's designed response to a
  # metadata generation changing under it — any app or plugin registration
  # causes one, and the catalog must be rebuilt rather than mutated in place.
  # OTP's default intensity of three restarts in five seconds therefore makes
  # the designed response fatal: a fourth registration inside that window ends
  # the application permanently, readiness never reopens, and every later action
  # fails closed with :product_not_ready. Measured directly — four rapid
  # restarts kill the application and unbind the kernel contracts for the
  # lifetime of the VM.
  #
  # The intensity is raised so ordinary composition churn is survivable while a
  # genuine restart loop, which cycles far faster than this, is still caught.
  @max_restarts 50
  @max_seconds 5

  @impl true
  def start(_type, _args) do
    children = [AllbertAssist.Pack.CompositionCoordinator]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: AllbertComposition.Supervisor,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
  end
end
