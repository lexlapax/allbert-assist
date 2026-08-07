defmodule AllbertAssist.Plugin.Registry.MetadataSnapshot do
  @moduledoc "Immutable ordered Plugin metadata captured at one structural generation."

  alias AllbertAssist.Plugin.Registry.MetadataEntry

  @enforce_keys [:schema_version, :generation, :entries]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema_version: 1,
          generation: non_neg_integer(),
          entries: [MetadataEntry.t()]
        }
end
