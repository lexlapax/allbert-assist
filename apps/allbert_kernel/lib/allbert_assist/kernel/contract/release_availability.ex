defmodule AllbertAssist.Kernel.Contract.ReleaseAvailability do
  @moduledoc """
  Release-availability admission for the relocated Runner.

  The residual owner decides whether a capability that is implemented in source
  is released for live use. That decision reads plugin registry state, so the
  kernel consumes it as a port.

  Unbound, live use is denied. This is the one contract whose closed value is a
  refusal rather than an absence: allowing an unreleased capability because the
  authority answering for it is missing would be exactly backwards. The denial
  reuses the Runner's existing `{status, decision}` shape so the response is the
  unavailable envelope it already builds, not a new vocabulary.
  """

  alias AllbertAssist.Kernel.Contract

  @closed_decision %{
    kind: :contract,
    id: :release_availability,
    decision: :product_not_ready,
    release_status: :product_not_ready
  }

  @callback ensure_live_use_allowed(term(), keyword()) :: :ok | {:error, {atom(), map()}}

  @doc "Allow live use of a capability reference, or deny with a decision."
  @spec ensure_live_use_allowed(term(), keyword()) :: :ok | {:error, {atom(), map()}}
  def ensure_live_use_allowed(ref, opts) do
    case Contract.fetch(:release_availability) do
      {:ok, implementation} -> implementation.ensure_live_use_allowed(ref, opts)
      {:error, _unbound} -> {:error, {:product_not_ready, @closed_decision}}
    end
  end
end
