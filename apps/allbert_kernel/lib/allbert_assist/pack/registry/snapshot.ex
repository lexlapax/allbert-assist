defmodule AllbertAssist.Pack.Registry.Snapshot do
  @moduledoc "Immutable Pack registry publication."

  alias AllbertAssist.Pack.{
    ActionBinding,
    CompatibilityAlias,
    CompatibilityDiagnostic,
    Contribution
  }

  @enforce_keys [
    :schema_version,
    :publication,
    :behavior_digest,
    :contributions,
    :effective_actions,
    :compatibility_aliases,
    :compatibility_diagnostics
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema_version: 1,
          publication: :shadow | :authoritative,
          behavior_digest: String.t(),
          contributions: [Contribution.t()],
          effective_actions: [ActionBinding.t()],
          compatibility_aliases: [CompatibilityAlias.t()],
          compatibility_diagnostics: [CompatibilityDiagnostic.t()]
        }
end
