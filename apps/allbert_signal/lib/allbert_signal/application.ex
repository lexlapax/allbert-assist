defmodule AllbertSignal.Application do
  # v1.4 M13: this pack is `native_effectful` (catalog.json) and owns its own
  # effect subtree -- the Signal adapter (and its signal-cli daemon, via
  # AllbertSignal.Supervisor) -- instead of the residual starting it.
  # Composition waits for this ActivationGate to ACK the same way it waits for
  # the residual's; see AllbertAssist.Pack.ActivationGate.
  @moduledoc false

  use Application

  alias AllbertAssist.Pack.ActivationGate

  @impl true
  def start(_type, _args) do
    children = [
      {ActivationGate,
       pack_id: "allbert_signal",
       effect_supervisor: AllbertSignal.EffectSupervisor,
       name: AllbertSignal.ActivationGate}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AllbertSignal.Supervisor)
  end
end
