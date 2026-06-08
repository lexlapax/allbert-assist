defmodule AllbertAssist.Artifacts do
  @moduledoc """
  Public artifact facade for the core content-addressable store.

  The artifact subsystem is plain module-backed storage, not a Jido agent: its
  durable state lives in Allbert Home as object files and markdown sidecars.
  Metadata lookup uses an opportunistic in-memory cache that can be rebuilt
  from disk.
  """

  alias AllbertAssist.Artifacts.Bounds
  alias AllbertAssist.Artifacts.MetadataIndex
  alias AllbertAssist.Artifacts.Store

  @doc "Store bytes and write allow-listed metadata for the resulting object."
  @spec put(binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def put(bytes, metadata \\ %{}, opts \\ []) when is_binary(bytes) and is_map(metadata) do
    with {:ok, bounds} <- Bounds.validate(bytes, metadata, opts),
         {:ok, object} <- Store.put(bytes, opts),
         metadata <- Map.merge(metadata, %{sha256: object.sha256, byte_size: object.byte_size}),
         metadata <- Map.put_new(metadata, :mime, bounds.mime),
         {:ok, indexed} <- MetadataIndex.write(metadata, opts) do
      {:ok, Map.put(object, :metadata, indexed)}
    end
  end

  @doc "Read object bytes by lowercase SHA-256."
  @spec read_object(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  defdelegate read_object(sha256, opts \\ []), to: Store, as: :read

  @doc "Read artifact metadata by lowercase SHA-256."
  @spec read_metadata(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate read_metadata(sha256, opts \\ []), to: MetadataIndex, as: :read

  @doc "List persisted artifact metadata records."
  @spec list_metadata(keyword()) :: {:ok, [map()]} | {:error, term()}
  defdelegate list_metadata(opts \\ []), to: MetadataIndex, as: :list
end
