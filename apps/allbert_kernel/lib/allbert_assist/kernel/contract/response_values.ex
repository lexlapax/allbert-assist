defmodule AllbertAssist.Kernel.Contract.ResponseValues do
  @moduledoc """
  Intent value serialization for the relocated canonical `Response`.

  `Response` renders three residual value types — the intent decision, its
  resource-access entries, and its approval handoff — into the canonical
  envelope. Only their serialization crosses the boundary, so the kernel keeps
  the one M3 response format and the residual keeps the struct definitions.
  Relocating those structs instead would have pulled the intent engine's
  registry, skills, and session dependencies behind them.

  ## Why `decision?/1` exists

  `Response` distinguishes a real decision struct from any other map, and the
  distinction is load-bearing rather than stylistic. `Decision.to_map/1` already
  converts nested resource access and drops empty values, so the struct clause
  and the plain-map clause produce different output for the same input. The
  kernel cannot pattern-match a struct it must not name, so it asks instead.
  The callbacks below are semantic operations rather than field readers for the
  same reason: the owner keeps its shape private and answers questions about it.

  Unbound, a decision is not recognized, values render as absent — `nil` for a
  value, `[]` for a collection — and `Response` takes the branches it already
  has for a turn that carried no decision. Nothing is fabricated.
  """

  alias AllbertAssist.Kernel.Contract

  @callback decision?(term()) :: boolean()
  @callback decision_to_map(term()) :: map() | nil
  @callback decision_diagnostics(term()) :: list()
  @callback decision_resource_access_maps(term()) :: [map()]
  @callback decision_approval_handoff_map(term()) :: map() | nil
  @callback resource_access_to_maps(term()) :: [map()]
  @callback approval_handoff_to_map(term()) :: map() | nil

  @doc "True when `term` is the owner's decision struct rather than a plain map."
  @spec decision?(term()) :: boolean()
  def decision?(term), do: call(:decision?, [term], false)

  @doc "Serialize an intent decision."
  @spec decision_to_map(term()) :: map() | nil
  def decision_to_map(decision), do: call(:decision_to_map, [decision], nil)

  @doc "Read a decision's diagnostics."
  @spec decision_diagnostics(term()) :: list()
  def decision_diagnostics(decision), do: call(:decision_diagnostics, [decision], [])

  @doc "Serialize the resource access carried by a decision."
  @spec decision_resource_access_maps(term()) :: [map()]
  def decision_resource_access_maps(decision),
    do: call(:decision_resource_access_maps, [decision], [])

  @doc "Serialize the approval handoff carried by a decision."
  @spec decision_approval_handoff_map(term()) :: map() | nil
  def decision_approval_handoff_map(decision),
    do: call(:decision_approval_handoff_map, [decision], nil)

  @doc "Serialize standalone resource-access entries."
  @spec resource_access_to_maps(term()) :: [map()]
  def resource_access_to_maps(entries), do: call(:resource_access_to_maps, [entries], [])

  @doc "Serialize a standalone approval handoff."
  @spec approval_handoff_to_map(term()) :: map() | nil
  def approval_handoff_to_map(handoff), do: call(:approval_handoff_to_map, [handoff], nil)

  defp call(fun, args, closed) do
    case Contract.fetch(:response_values) do
      {:ok, implementation} -> apply(implementation, fun, args)
      {:error, _unbound} -> closed
    end
  end
end
