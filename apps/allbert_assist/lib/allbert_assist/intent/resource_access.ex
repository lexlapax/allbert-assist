defmodule AllbertAssist.Intent.ResourceAccess do
  @moduledoc """
  Inert resource-access posture attached to an intent decision.

  This wraps the v0.10 `AllbertAssist.Resources.Ref` contract with the extra
  fields v0.11 channels need for approval handoff and traces. It never reads,
  fetches, imports, installs, or executes.
  """

  alias AllbertAssist.Resources.Ref

  @enforce_keys [
    :resource_uri,
    :origin_kind,
    :canonical_id,
    :operation_class,
    :access_mode,
    :scope
  ]
  defstruct [
    :resource_uri,
    :display_uri,
    :origin_kind,
    :canonical_id,
    :source,
    :operation_class,
    :access_mode,
    :scope,
    :expected_content_kind,
    :accepted_content_types,
    :byte_cap,
    :output_cap,
    :redirect_policy,
    :retry_policy,
    :digest,
    :cache,
    :downstream_consumer,
    :parser,
    :summarizer,
    :origin,
    :response_target,
    :target_action,
    unsupported?: false,
    allowed_approval_scopes: [],
    diagnostics: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          resource_uri: String.t(),
          display_uri: String.t() | nil,
          origin_kind: atom(),
          canonical_id: String.t(),
          source: String.t() | nil,
          operation_class: atom(),
          access_mode: atom(),
          scope: map(),
          expected_content_kind: atom() | String.t() | nil,
          accepted_content_types: [String.t()] | nil,
          byte_cap: pos_integer() | nil,
          output_cap: pos_integer() | nil,
          redirect_policy: atom() | String.t() | nil,
          retry_policy: atom() | String.t() | nil,
          digest: String.t() | nil,
          cache: atom() | String.t() | nil,
          downstream_consumer: atom() | String.t() | nil,
          parser: atom() | String.t() | nil,
          summarizer: atom() | String.t() | nil,
          origin: map() | nil,
          response_target: String.t() | nil,
          target_action: String.t() | nil,
          unsupported?: boolean(),
          allowed_approval_scopes: [atom()],
          diagnostics: [map()],
          metadata: map()
        }

  @spec new(t() | Ref.t() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = access), do: validate(access)

  def new(%Ref{} = ref), do: ref |> Ref.to_map() |> new()

  def new(attrs) when is_map(attrs) do
    with {:ok, ref} <- Ref.new(attrs) do
      {:ok, build_access(attrs, ref)}
    end
  end

  def new(value), do: {:error, {:invalid_resource_access, value}}

  @spec new!(t() | Ref.t() | map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, access} -> access
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{} = access) do
    attrs = %{
      resource_uri: access.resource_uri,
      origin_kind: access.origin_kind,
      operation_class: access.operation_class,
      access_mode: access.access_mode,
      scope: access.scope,
      downstream_consumer: access.downstream_consumer,
      digest: access.digest,
      display_uri: access.display_uri,
      source_profile: access.source,
      metadata: access.metadata
    }

    case Ref.new(attrs) do
      {:ok, _ref} -> {:ok, access}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec to_map(t() | map()) :: map()
  def to_map(%__MODULE__{} = access) do
    %{
      resource_uri: access.resource_uri,
      display_uri: access.display_uri,
      origin_kind: access.origin_kind,
      canonical_id: access.canonical_id,
      source: access.source,
      operation_class: access.operation_class,
      access_mode: access.access_mode,
      scope: access.scope,
      expected_content_kind: access.expected_content_kind,
      accepted_content_types: access.accepted_content_types,
      byte_cap: access.byte_cap,
      output_cap: access.output_cap,
      redirect_policy: access.redirect_policy,
      retry_policy: access.retry_policy,
      digest: access.digest,
      cache: access.cache,
      downstream_consumer: access.downstream_consumer,
      parser: access.parser,
      summarizer: access.summarizer,
      origin: access.origin,
      response_target: access.response_target,
      target_action: access.target_action,
      unsupported?: access.unsupported?,
      allowed_approval_scopes: access.allowed_approval_scopes,
      diagnostics: access.diagnostics,
      metadata: access.metadata
    }
    |> drop_empty_values()
  end

  def to_map(access) when is_map(access), do: access

  @spec to_maps([t() | map()]) :: [map()]
  def to_maps(entries) when is_list(entries), do: Enum.map(entries, &to_map/1)

  @spec summary(t() | map()) :: map()
  def summary(access), do: to_map(access)

  defp build_access(attrs, %Ref{} = ref) do
    ref_map = Ref.to_map(ref)
    limits = map_field(ref_map, :limits)
    metadata = map_field(ref_map, :metadata)

    %__MODULE__{
      resource_uri: ref_map.resource_uri,
      display_uri: first_present([field(attrs, :display_uri), field(ref_map, :display_uri)]),
      origin_kind: ref_map.origin_kind,
      canonical_id: ref_map.canonical_id,
      source: first_present([field(attrs, :source), field(ref_map, :source_profile)]),
      operation_class: ref_map.operation_class,
      access_mode: ref_map.access_mode,
      scope: ref_map.scope,
      expected_content_kind: field(attrs, :expected_content_kind),
      accepted_content_types: field(attrs, :accepted_content_types),
      byte_cap: field(attrs, :byte_cap) || field(limits, :max_response_bytes),
      output_cap: output_cap(attrs, limits),
      redirect_policy:
        first_present([field(attrs, :redirect_policy), field(metadata, :allow_redirects?)]),
      retry_policy: first_present([field(attrs, :retry_policy), field(metadata, :retry_policy)]),
      digest: first_present([field(attrs, :digest), field(ref_map, :digest)]),
      cache: field(attrs, :cache),
      downstream_consumer:
        first_present([field(attrs, :downstream_consumer), ref_map.downstream_consumer]),
      parser: field(attrs, :parser),
      summarizer: field(attrs, :summarizer),
      origin: field(attrs, :origin),
      response_target: field(attrs, :response_target),
      target_action: field(attrs, :target_action),
      unsupported?: field(ref_map, :unsupported?, false),
      allowed_approval_scopes: normalize_list(field(attrs, :allowed_approval_scopes)),
      diagnostics: normalize_list(field(attrs, :diagnostics)),
      metadata: Map.merge(metadata, map_field(attrs, :metadata))
    }
  end

  defp output_cap(attrs, limits) do
    first_present([
      field(attrs, :output_cap),
      field(limits, :max_output_bytes),
      field(limits, :max_download_bytes)
    ])
  end

  defp map_field(map, key) do
    case field(map, key, %{}) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end

  defp first_present(values), do: Enum.find(values, &present?/1)

  defp present?(value), do: value not in [nil, "", [], %{}]

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default

  defp normalize_list(nil), do: []
  defp normalize_list(list) when is_list(list), do: list
  defp normalize_list(value), do: [value]

  defp drop_empty_values(map) do
    Map.reject(map, fn
      {_key, nil} -> true
      {_key, value} when value == %{} -> true
      {_key, value} when value == [] -> true
      _entry -> false
    end)
  end
end
