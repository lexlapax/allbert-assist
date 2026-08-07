defmodule AllbertAssist.App.Registry.MetadataSnapshot do
  @moduledoc "Immutable ordered App metadata captured at one structural generation."

  alias AllbertAssist.App.Registry.MetadataEntry

  @enforce_keys [:schema_version, :generation, :entries]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema_version: 1,
          generation: non_neg_integer(),
          entries: [MetadataEntry.t()]
        }
end
