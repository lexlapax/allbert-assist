defmodule AllbertAssist.Pack.Owner do
  @moduledoc "Typed owner of one Pack contribution."

  @enforce_keys [:schema_version, :kind, :id, :application]
  defstruct @enforce_keys

  @type kind :: :compiled_pack | :legacy_plugin | :declared_pack

  @type t :: %__MODULE__{
          schema_version: 1,
          kind: kind(),
          id: String.t(),
          application: atom() | nil
        }
end

defmodule AllbertAssist.Pack.Order do
  @moduledoc "Typed stable order carried by one Pack contribution owner."

  @enforce_keys [:schema_version, :namespace, :value]
  defstruct @enforce_keys

  @type namespace :: :compiled_pack | :legacy_plugin | :declared_pack

  @type t :: %__MODULE__{
          schema_version: 1,
          namespace: namespace(),
          value: non_neg_integer() | String.t()
        }
end

defmodule AllbertAssist.Pack.Compatibility do
  @moduledoc "Typed compatibility disposition for one Pack contribution."

  alias AllbertAssist.Pack.Target

  @enforce_keys [:schema_version, :kind, :legacy_id, :alias_of, :trust, :enabled]
  defstruct @enforce_keys

  @type kind :: :native | :legacy_plugin | :declared | :deprecated_alias
  @type trust :: :trusted | :pending | :untrusted

  @type t :: %__MODULE__{
          schema_version: 1,
          kind: kind(),
          legacy_id: String.t() | nil,
          alias_of: Target.t() | nil,
          trust: trust(),
          enabled: boolean()
        }
end

defmodule AllbertAssist.Pack.Contribution do
  @moduledoc "One complete, inert Pack contribution."

  alias AllbertAssist.Pack.{Compatibility, Descriptor, Order, Owner, Row}

  @enforce_keys [
    :schema_version,
    :owner,
    :implementation_module,
    :descriptor,
    :source_lane,
    :owner_order,
    :compatibility,
    :callbacks
  ]
  defstruct @enforce_keys

  @type source_lane :: :native | :legacy_plugin | :declared
  @type rows :: [Row.t()]

  @type callbacks :: %{
          required(:apps) => rows(),
          required(:actions) => rows(),
          required(:settings_fragments) => rows(),
          required(:settings_migrations) => rows(),
          required(:channels) => rows(),
          required(:surfaces) => rows(),
          required(:skill_roots) => rows(),
          required(:home_roots) => rows(),
          required(:jobs) => rows(),
          required(:stores) => rows(),
          required(:prompt_rules) => rows(),
          required(:intent_descriptors) => rows(),
          required(:cli_groups) => rows(),
          required(:release_assets) => rows(),
          required(:test_lanes) => rows()
        }

  @type t :: %__MODULE__{
          schema_version: 1,
          owner: Owner.t(),
          implementation_module: module() | nil,
          descriptor: Descriptor.t() | nil,
          source_lane: source_lane(),
          owner_order: Order.t(),
          compatibility: Compatibility.t(),
          callbacks: callbacks()
        }
end
