defmodule AllbertAssist.Pack.Target do
  @moduledoc "Typed target for a contribution or effective action."

  @enforce_keys [:schema_version, :kind, :owner_id, :identity]
  defstruct @enforce_keys

  @type kind :: :contribution | :action

  @type t :: %__MODULE__{
          schema_version: 1,
          kind: kind(),
          owner_id: String.t(),
          identity: String.t()
        }
end
