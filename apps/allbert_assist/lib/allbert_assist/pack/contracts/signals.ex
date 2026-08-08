defmodule AllbertAssist.Pack.Contracts.Signals do
  @moduledoc "Residual provider for the kernel `Signals` contract."

  @behaviour AllbertAssist.Kernel.Contract.Signals

  alias AllbertAssist.Signals

  @impl true
  defdelegate action_requested(name, module, params, context), to: Signals

  @impl true
  defdelegate action_completed(name, module, status, response, context, duration_ms), to: Signals

  @impl true
  defdelegate log(signal), to: Signals

  @impl true
  defdelegate emit_registration(reason, metadata), to: Signals
end
