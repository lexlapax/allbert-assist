defmodule AllbertAssist.Pack.ActionBinding do
  @moduledoc "Effective action binding captured for one immutable Pack snapshot."

  @enforce_keys [
    :schema_version,
    :module,
    :name,
    :source_lane,
    :legacy_index,
    :registry_order,
    :normalized_capability,
    :m0_row_sha256,
    :input_schema_sha256,
    :output_schema_sha256
  ]
  defstruct @enforce_keys

  @type source_lane :: :native_static | :legacy_plugin

  @type normalized_capability :: %{
          required(:app_id) => atom() | nil,
          required(:confirmation) => atom() | nil,
          required(:execution_mode) => atom(),
          required(:exposure) => :agent | :internal,
          required(:notes) => String.t() | nil,
          required(:permission) => atom(),
          required(:plugin_id) => String.t() | nil,
          required(:resumable?) => boolean(),
          required(:retry_safety) => atom(),
          required(:skill_backed?) => boolean()
        }

  @type t :: %__MODULE__{
          schema_version: 1,
          module: module(),
          name: String.t(),
          source_lane: source_lane(),
          legacy_index: pos_integer(),
          registry_order: non_neg_integer() | nil,
          normalized_capability: normalized_capability(),
          m0_row_sha256: String.t(),
          input_schema_sha256: String.t(),
          output_schema_sha256: String.t()
        }
end
