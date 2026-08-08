defmodule AllbertAssist.Pack.Contracts.Confirmations do
  @moduledoc "Residual provider for the kernel `Confirmations` contract."

  @behaviour AllbertAssist.Kernel.Contract.Confirmations

  alias AllbertAssist.Confirmations

  @impl true
  defdelegate list(opts), to: Confirmations
end
