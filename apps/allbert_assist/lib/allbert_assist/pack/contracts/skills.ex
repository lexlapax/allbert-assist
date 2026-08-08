defmodule AllbertAssist.Pack.Contracts.Skills do
  @moduledoc "Residual provider for the kernel `Skills` contract."

  @behaviour AllbertAssist.Kernel.Contract.Skills

  alias AllbertAssist.Skills

  @impl true
  defdelegate get(name, context), to: Skills
end
