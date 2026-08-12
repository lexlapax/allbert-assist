defmodule AllbertEmail.Application do
  # v1.4 M13: this pack is `native_effectful` (catalog.json) and owns its own
  # effect subtree -- the Email adapter -- instead of the residual starting
  # it. Composition waits for this ActivationGate to ACK the same way it waits
  # for the residual's; see AllbertAssist.Pack.ActivationGate.
  @moduledoc false

  use Application

  alias AllbertAssist.Pack.ActivationGate

  @impl true
  def start(_type, _args) do
    children = [
      {ActivationGate,
       pack_id: "allbert_email",
       effect_supervisor: AllbertEmail.EffectSupervisor,
       name: AllbertEmail.ActivationGate}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AllbertEmail.Supervisor)
  end
end
