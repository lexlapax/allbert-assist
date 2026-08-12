defmodule AllbertDiscord.Application do
  # v1.4 M13: this pack is `native_effectful` (catalog.json) and owns its own
  # effect subtree -- the Discord adapter -- instead of the residual starting
  # it. Composition waits for this ActivationGate to ACK the same way it waits
  # for the residual's; see AllbertAssist.Pack.ActivationGate.
  @moduledoc false

  use Application

  alias AllbertAssist.Pack.ActivationGate

  @impl true
  def start(_type, _args) do
    children = [
      {ActivationGate,
       pack_id: "allbert_discord",
       effect_supervisor: AllbertDiscord.EffectSupervisor,
       name: AllbertDiscord.ActivationGate}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AllbertDiscord.Supervisor)
  end
end
