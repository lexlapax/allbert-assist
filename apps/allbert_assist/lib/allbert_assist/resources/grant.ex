defmodule AllbertAssist.Resources.Grant do
  @moduledoc """
  Inert remembered-grant descriptor for resource access posture.

  v0.10 M8 stores and matches grants through `AllbertAssist.Resources.Grants`.
  Grant data is still not execution authority: callers must re-check policy
  and current resource params before using a remembered grant.
  """

  alias AllbertAssist.Resources.Ref

  @enforce_keys [:origin_kind, :scope_kind, :canonical_scope, :operation_class, :access_mode]
  defstruct [
    :id,
    :origin_kind,
    :scope_kind,
    :canonical_scope,
    :operation_class,
    :access_mode,
    :downstream_consumer,
    :origin_channel,
    :resolver_channel,
    :reason,
    :created_at,
    :expires_at,
    :revoked_at,
    :audit_path,
    metadata: %{}
  ]

  @type t :: %__MODULE__{}

  @spec from_ref(map() | Ref.t(), map()) :: t()
  def from_ref(resource_ref, attrs \\ %{}) do
    ref = if match?(%Ref{}, resource_ref), do: Ref.to_map(resource_ref), else: resource_ref
    scope = Map.get(ref, :scope) || Map.get(ref, "scope") || %{}

    %__MODULE__{
      id: field(attrs, :id),
      origin_kind: field(ref, :origin_kind),
      scope_kind: field(scope, :kind),
      canonical_scope: field(scope, :value),
      operation_class: field(ref, :operation_class),
      access_mode: field(ref, :access_mode),
      downstream_consumer: field(ref, :downstream_consumer),
      origin_channel: field(attrs, :origin_channel),
      resolver_channel: field(attrs, :resolver_channel),
      reason: field(attrs, :reason),
      created_at: field(attrs, :created_at),
      expires_at: field(attrs, :expires_at),
      revoked_at: field(attrs, :revoked_at),
      audit_path: field(attrs, :audit_path),
      metadata: field(attrs, :metadata, %{})
    }
  end

  @spec same_authority?(t(), t()) :: boolean()
  def same_authority?(%__MODULE__{} = left, %__MODULE__{} = right) do
    Map.take(Map.from_struct(left), authority_fields()) ==
      Map.take(Map.from_struct(right), authority_fields())
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = grant) do
    grant
    |> Map.from_struct()
    |> Map.reject(fn {_key, value} -> value in [nil, %{}] end)
  end

  defp authority_fields do
    [
      :origin_kind,
      :scope_kind,
      :canonical_scope,
      :operation_class,
      :access_mode,
      :downstream_consumer
    ]
  end

  defp field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
