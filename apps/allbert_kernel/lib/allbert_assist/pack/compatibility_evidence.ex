defmodule AllbertAssist.Pack.PathSegment do
  @moduledoc "Typed, root-independent path segment used in Pack diagnostics."

  @enforce_keys [:schema_version, :kind, :value]
  defstruct @enforce_keys

  @type kind :: :field | :index | :identity

  @type t :: %__MODULE__{
          schema_version: 1,
          kind: kind(),
          value: String.t() | non_neg_integer()
        }
end

defmodule AllbertAssist.Pack.ChildSpecProjection do
  @moduledoc "Canonical, non-executable projection of one legacy child specification."

  @enforce_keys [
    :schema_version,
    :id,
    :start_module,
    :start_function,
    :start_arity,
    :start_args_sha256,
    :restart,
    :shutdown,
    :type
  ]
  defstruct @enforce_keys

  @type canonical_child_id :: String.t() | integer() | map()

  @type t :: %__MODULE__{
          schema_version: 1,
          id: canonical_child_id() | nil,
          start_module: String.t() | nil,
          start_function: String.t() | nil,
          start_arity: non_neg_integer() | nil,
          start_args_sha256: String.t() | nil,
          restart: String.t() | nil,
          shutdown: non_neg_integer() | String.t() | nil,
          type: String.t() | nil
        }
end

defmodule AllbertAssist.Pack.CompatibilityAlias do
  @moduledoc "Typed compatibility alias bound to reproducible authority bytes."

  alias AllbertAssist.Pack.Target

  @enforce_keys [:schema_version, :kind, :owner_id, :target, :module, :authority_sha256]
  defstruct @enforce_keys

  @type kind :: :legacy_plugin | :deprecated_alias

  @type t :: %__MODULE__{
          schema_version: 1,
          kind: kind(),
          owner_id: String.t(),
          target: Target.t(),
          module: module() | nil,
          authority_sha256: String.t()
        }
end

defmodule AllbertAssist.Pack.CompatibilityDiagnostic do
  @moduledoc "Parity-bound compatibility evidence stored in a Pack snapshot."

  alias AllbertAssist.Pack.{OwnerRef, PathSegment}

  @enforce_keys [:schema_version, :code, :severity, :path, :owner, :detail]
  defstruct @enforce_keys

  @type code ::
          :legacy_registry | :disabled_plugin | :deprecated_alias | :child_spec | :collision

  @type severity :: :warning | :error

  @type t :: %__MODULE__{
          schema_version: 1,
          code: code(),
          severity: severity(),
          path: [PathSegment.t()],
          owner: OwnerRef.t() | nil,
          detail: map()
        }
end

defmodule AllbertAssist.Pack.ValidationDiagnostic do
  @moduledoc "Non-persisted diagnostic returned when Pack finalization rejects input."

  alias AllbertAssist.Pack.{OwnerRef, PathSegment}

  @enforce_keys [:schema_version, :code, :path, :owner, :detail]
  defstruct @enforce_keys

  @type code ::
          :not_coordinator
          | :unsupported_schema_version
          | :missing_field
          | :unknown_field
          | :invalid_type
          | :invalid_value
          | :duplicate_identity
          | :duplicate_order
          | :owner_mismatch
          | :alias_mismatch
          | :digest_mismatch
          | :canonicalization_rejected

  @type t :: %__MODULE__{
          schema_version: 1,
          code: code(),
          path: [PathSegment.t()],
          owner: OwnerRef.t() | nil,
          detail: map()
        }
end
