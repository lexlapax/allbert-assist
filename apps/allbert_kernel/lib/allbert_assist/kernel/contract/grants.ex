defmodule AllbertAssist.Kernel.Contract.Grants do
  @moduledoc """
  Coding command grants for relocated Security Context and Decision.

  A grant is an operator-established narrowing that Security consults while
  building context and rendering a decision. It is input to authorization, not a
  substitute for it.

  Unbound, no grant is applicable and no reference canonicalizes. That is the
  fail-closed direction: an absent grant authority removes a narrowing that
  could only ever have widened what a decision reports, never adds one.
  """

  alias AllbertAssist.Kernel.Contract

  @callback applicable?(atom(), map()) :: boolean()
  @callback canonical_ref(term()) :: {:ok, map()} | {:error, term()}
  @callback redacted_ref(term()) :: term()

  @doc "True when a command grant applies to `permission` in this context."
  @spec applicable?(atom(), map()) :: boolean()
  def applicable?(permission, context), do: call(:applicable?, [permission, context], false)

  @doc "Canonicalize command params into a grant reference."
  @spec canonical_ref(term()) :: {:ok, map()} | {:error, term()}
  def canonical_ref(params), do: call(:canonical_ref, [params], {:error, :product_not_ready})

  @doc "Redact a grant reference for context and audit."
  @spec redacted_ref(term()) :: term()
  def redacted_ref(ref), do: call(:redacted_ref, [ref], nil)

  defp call(fun, args, closed) do
    case Contract.fetch(:grants) do
      {:ok, implementation} -> apply(implementation, fun, args)
      {:error, _unbound} -> closed
    end
  end
end
