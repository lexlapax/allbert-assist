defmodule AllbertAssist.Pack.Contracts.ReleaseAvailability do
  @moduledoc "Residual provider for the kernel `ReleaseAvailability` contract."

  @behaviour AllbertAssist.Kernel.Contract.ReleaseAvailability

  alias AllbertAssist.Capabilities.ReleaseAvailability

  @impl true
  defdelegate ensure_live_use_allowed(ref, opts), to: ReleaseAvailability
end
