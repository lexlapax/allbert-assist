defmodule AllbertAssist.Pack.Row do
  @moduledoc "One normalized inert row returned by a Pack contribution callback."

  @enforce_keys [
    :schema_version,
    :kind,
    :owner_id,
    :identity,
    :order,
    :payload_schema,
    :payload,
    :source_authority,
    :m0_payload_sha256
  ]
  defstruct @enforce_keys

  @type canonical_json_value ::
          nil
          | boolean()
          | number()
          | String.t()
          | [canonical_json_value()]
          | %{optional(String.t()) => canonical_json_value()}

  @type identity :: %{required(:namespace) => atom(), required(:value) => String.t()}

  @type order :: %{
          required(:namespace) => atom(),
          required(:value) => non_neg_integer() | String.t()
        }

  @type t :: %__MODULE__{
          schema_version: 1,
          kind: atom(),
          owner_id: String.t(),
          identity: identity(),
          order: order(),
          payload_schema: atom(),
          payload: canonical_json_value(),
          source_authority: %{optional(String.t()) => canonical_json_value()} | nil,
          m0_payload_sha256: String.t() | nil
        }
end
