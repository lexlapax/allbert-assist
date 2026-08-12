defmodule AllbertMatrix.Application do
  # v1.4 M13: this pack is `native_effectful` (catalog.json) and owns its own
  # effect subtree -- the Matrix adapter -- instead of the residual starting
  # it. Composition waits for this ActivationGate to ACK the same way it waits
  # for the residual's; see AllbertAssist.Pack.ActivationGate.
  @moduledoc false

  use Application

  alias AllbertAssist.Pack.ActivationGate

  @impl true
  def start(_type, _args) do
    children = [
      {ActivationGate,
       pack_id: "allbert_matrix",
       effect_supervisor: AllbertMatrix.EffectSupervisor,
       name: AllbertMatrix.ActivationGate}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AllbertMatrix.Supervisor)
  end
end
