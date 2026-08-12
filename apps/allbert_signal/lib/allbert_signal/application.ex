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

    # Named AppSupervisor, not `AllbertSignal.Supervisor`: that name is already
    # taken by the adapter's own Supervisor (apps/allbert_signal/lib/allbert_signal/supervisor.ex),
    # which the channel descriptor's `child_spec` starts as an effect child.
    # Reusing it here would make the two start_link/1 calls race for one
    # registered name and the second one would fail with `{:already_started, _}`.
    Supervisor.start_link(children, strategy: :one_for_one, name: AllbertSignal.AppSupervisor)
  end
end
