defmodule AllbertAssist.Actions.Registry.CandidateProjection do
  @moduledoc """
  Pure action projection consumed by the v1.4 Pack candidate builder.

  `effective` preserves runtime order. `plugin_declarations` preserves every
  enabled Plugin declaration, including declarations displaced by precedence.
  `alias_sources` is the corresponding ordered displaced subset. A displaced
  declaration has one of `:static_module`, `:static_name`, or
  `:duplicate_plugin_name` in its `:disposition` field.
  """

  @enforce_keys [:effective, :plugin_declarations, :alias_sources]
  defstruct @enforce_keys

  @type projection :: %{
          required(:legacy_index) => pos_integer() | nil,
          required(:module) => module(),
          required(:name) => String.t(),
          required(:normalized_capability) => map(),
          required(:input_schema_sha256) => String.t(),
          required(:output_schema_sha256) => String.t(),
          required(:app_id) => atom() | nil,
          required(:plugin_id) => String.t() | nil,
          optional(:disposition) =>
            :effective | :static_module | :static_name | :duplicate_plugin_name
        }

  @type t :: %__MODULE__{
          effective: [projection()],
          plugin_declarations: [projection()],
          alias_sources: [projection()]
        }
end
