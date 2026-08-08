defmodule AllbertAssist.Kernel.Contract.ResponseValues do
  @moduledoc """
  Intent value serialization for the relocated canonical `Response`.

  `Response` renders three residual value types — the intent decision, its
  resource-access entries, and its approval handoff — into the canonical
  envelope. Only their serialization crosses the boundary, so the kernel keeps
  the one M3 response format and the residual keeps the struct definitions.
  Relocating those structs instead would have pulled the intent engine's
  registry, skills, and session dependencies behind them.

  Unbound, each renders as absent — `nil` for a value, `[]` for a collection —
  which are shapes `Response` already produces for a turn that carried no
  decision. Nothing is fabricated.
  """

  alias AllbertAssist.Kernel.Contract

  @callback decision_to_map(term()) :: map() | nil
  @callback decision_diagnostics(term()) :: term()
  @callback resource_access_to_maps(term()) :: [map()]
  @callback approval_handoff_to_map(term()) :: map() | nil

  @doc "Serialize an intent decision."
  @spec decision_to_map(term()) :: map() | nil
  def decision_to_map(decision), do: call(:decision_to_map, [decision], nil)

  @doc "Read an intent decision's diagnostics."
  @spec decision_diagnostics(term()) :: term()
  def decision_diagnostics(decision), do: call(:decision_diagnostics, [decision], nil)

  @doc "Serialize resource-access entries."
  @spec resource_access_to_maps(term()) :: [map()]
  def resource_access_to_maps(entries), do: call(:resource_access_to_maps, [entries], [])

  @doc "Serialize an approval handoff."
  @spec approval_handoff_to_map(term()) :: map() | nil
  def approval_handoff_to_map(handoff), do: call(:approval_handoff_to_map, [handoff], nil)

  defp call(fun, args, closed) do
    case Contract.fetch(:response_values) do
      {:ok, implementation} -> apply(implementation, fun, args)
      {:error, _unbound} -> closed
    end
  end
end
