defmodule AllbertAssist.Pack.Registry.Candidate do
  @moduledoc """
  Complete, pre-publication Pack registry candidate.

  Candidates are immutable data. The Registry validates and canonicalizes the
  whole value before publishing any snapshot.
  """

  alias AllbertAssist.Pack.{
    ActionBinding,
    CompatibilityAlias,
    CompatibilityDiagnostic,
    Contribution
  }

  @enforce_keys [
    :schema_version,
    :contributions,
    :action_bindings,
    :compatibility_aliases,
    :compatibility_diagnostics
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema_version: 1,
          contributions: [Contribution.t()],
          action_bindings: [ActionBinding.t()],
          compatibility_aliases: [CompatibilityAlias.t()],
          compatibility_diagnostics: [CompatibilityDiagnostic.t()]
        }
end
