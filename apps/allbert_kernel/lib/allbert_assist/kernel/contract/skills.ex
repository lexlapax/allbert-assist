defmodule AllbertAssist.Kernel.Contract.Skills do
  @moduledoc """
  Skill lookup for relocated Security Context.

  Security records which skill a turn selected so a decision can explain itself.
  Skill trust and enablement policy stay with the skill registry in the residual
  pack; the kernel reads the resolved declaration and grants nothing from it.

  Unbound, lookup returns `{:error, :not_found}` — the same result
  `Security.Context` already produces when the registry raises or the name does
  not resolve, so the context falls through to its metadata-only branch.
  """

  alias AllbertAssist.Kernel.Contract

  @callback get(term(), map()) :: term()

  @doc "Resolve one skill declaration by name for a decision context."
  @spec get(term(), map()) :: term()
  def get(name, context) do
    case Contract.fetch(:skills) do
      {:ok, implementation} -> implementation.get(name, context)
      {:error, _unbound} -> {:error, :not_found}
    end
  end
end
