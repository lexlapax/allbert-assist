defmodule AllbertAssist.Pack.Contracts.ResourceRefs do
  @moduledoc "Residual provider for the kernel `ResourceRefs` contract."

  @behaviour AllbertAssist.Kernel.Contract.ResourceRefs

  alias AllbertAssist.Resources.Ref

  @impl true
  defdelegate from_external_request_summary(summary), to: Ref
end
