defmodule AllbertAssist.Pack.ActivationContext do
  @moduledoc """
  Opaque, short-lived carrier for one authorizing Pack activation gate.

  The carrier is a liveness proof only. It is neither public context nor a
  Security authority and must be consumed by an activation-owned boot worker.
  """

  @enforce_keys [
    :schema_version,
    :pack_id,
    :gate_pid,
    :barrier_pid,
    :subscription_ref,
    :snapshot_digest
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema_version: 1,
          pack_id: String.t(),
          gate_pid: pid(),
          barrier_pid: pid(),
          subscription_ref: reference(),
          snapshot_digest: String.t()
        }
end
