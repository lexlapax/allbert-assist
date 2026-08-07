defmodule AllbertAssist.Pack.OwnerRef do
  @moduledoc "Application-free reference to a Pack contribution owner."

  alias AllbertAssist.Pack.Owner

  @enforce_keys [:schema_version, :kind, :id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema_version: 1,
          kind: Owner.kind(),
          id: String.t()
        }
end
