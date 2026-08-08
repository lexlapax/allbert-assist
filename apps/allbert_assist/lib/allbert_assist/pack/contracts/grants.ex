defmodule AllbertAssist.Pack.Contracts.Grants do
  @moduledoc "Residual provider for the kernel `Grants` contract."

  @behaviour AllbertAssist.Kernel.Contract.Grants

  alias AllbertAssist.Coding.CommandGrants

  @impl true
  defdelegate applicable?(permission, context), to: CommandGrants

  @impl true
  defdelegate canonical_ref(params), to: CommandGrants

  @impl true
  defdelegate redacted_ref(ref), to: CommandGrants
end
