defmodule AllbertAssist.Artifacts do
  @moduledoc """
  Public artifact facade for the core content-addressable store.

  The artifact subsystem is plain module-backed storage, not a Jido agent: its
  durable state lives in Allbert Home as object files and markdown sidecars.
  Metadata lookup uses an opportunistic in-memory cache that can be rebuilt
  from disk.
  """

  alias AllbertAssist.Artifacts.Bounds
  alias AllbertAssist.Artifacts.Config
  alias AllbertAssist.Artifacts.MetadataIndex
  alias AllbertAssist.Artifacts.Store
  alias AllbertAssist.Artifacts.ThreadLinks
  alias AllbertAssist.Resources.ResourceURI

  @doc "Store bytes and write allow-listed metadata for the resulting object."
  @spec put(binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def put(bytes, metadata \\ %{}, opts \\ []) when is_binary(bytes) and is_map(metadata) do
    opts = Config.with_bounds(opts)

    with {:ok, bounds} <- Bounds.validate(bytes, metadata, opts),
         {:ok, object} <- Store.put(bytes, opts),
         metadata <- Map.merge(metadata, %{sha256: object.sha256, byte_size: object.byte_size}),
         metadata <- Map.put_new(metadata, :mime, bounds.mime),
         {:ok, indexed} <- MetadataIndex.write(metadata, opts) do
      {:ok, Map.put(object, :metadata, indexed)}
    end
  end

  @doc "Store bytes through the Settings-backed retained-artifact policy."
  @spec put_retained(binary(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def put_retained(bytes, metadata \\ %{}, opts \\ [])
      when is_binary(bytes) and is_map(metadata) do
    context = Keyword.get(opts, :context, %{})

    with :ok <- ensure_write_enabled(),
         :ok <- ensure_retention_enabled(),
         metadata <- retained_metadata(metadata),
         metadata <- ThreadLinks.put_provenance(metadata, context, :created_by),
         {:ok, artifact} <- put(bytes, metadata, opts),
         {:ok, _link} <- ThreadLinks.record_created(artifact.sha256, context, opts) do
      {:ok, public_artifact(artifact)}
    end
  end

  @doc "Read artifact metadata and optionally bytes by SHA-256 or artifact URI."
  @spec get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(artifact_ref, opts \\ []) do
    include_bytes? = Keyword.get(opts, :include_bytes?, false)

    with {:ok, sha256} <- normalize_ref(artifact_ref),
         {:ok, metadata} <- MetadataIndex.lookup(sha256, opts),
         {:ok, bytes} <- maybe_read_bytes(sha256, include_bytes?, opts) do
      artifact =
        %{
          sha256: sha256,
          artifact_uri: artifact_uri(sha256),
          metadata: metadata
        }
        |> maybe_put(:bytes, bytes)

      {:ok, artifact}
    end
  end

  @doc "List artifact metadata records with lightweight filters."
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ []) do
    with {:ok, since} <- normalize_since(Keyword.get(opts, :since)),
         {:ok, records} <- list_source_records(opts) do
      records
      |> Enum.map(&metadata_artifact/1)
      |> filter_records(opts, since)
      |> limit_records(Keyword.get(opts, :limit))
      |> then(&{:ok, &1})
    end
  end

  @doc "Return user-scoped thread/message links for one artifact."
  @spec artifact_threads(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def artifact_threads(artifact_ref, opts \\ []) do
    with {:ok, sha256} <- normalize_ref(artifact_ref),
         {:ok, user_id} <- required_opt(opts, :user_id, :missing_user_id),
         {:ok, links} <- ThreadLinks.list_for_artifact(user_id, sha256, opts) do
      links
      |> Enum.map(&ThreadLinks.public_link/1)
      |> then(&{:ok, &1})
    end
  end

  @doc "Delete artifact bytes and metadata by SHA-256 or artifact URI."
  @spec delete(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete(artifact_ref, opts \\ []) do
    with {:ok, sha256} <- normalize_ref(artifact_ref),
         {:ok, metadata} <- MetadataIndex.lookup(sha256, opts),
         {:ok, object_delete} <- Store.delete(sha256, opts),
         metadata_delete <- delete_metadata(sha256, opts) do
      {:ok,
       %{
         sha256: sha256,
         artifact_uri: artifact_uri(sha256),
         metadata: metadata,
         deleted: %{object: object_delete, metadata: metadata_delete}
       }}
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

  @doc "Return the canonical artifact URI for a SHA-256 digest."
  @spec artifact_uri(String.t()) :: String.t()
  def artifact_uri(sha256), do: ResourceURI.artifact!(sha256)

  @doc false
  @spec normalize_ref(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize_ref(ref) when is_binary(ref) do
    cond do
      Store.valid_sha256?(ref) ->
        {:ok, ref}

      String.starts_with?(ref, "artifact://") ->
        case ResourceURI.derived_fields(ref) do
          {:ok, %{sha256: sha256}} -> {:ok, sha256}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, :invalid_sha256}
    end
  end

  def normalize_ref(_ref), do: {:error, :invalid_sha256}

  defp ensure_write_enabled do
    if Config.enabled?(), do: :ok, else: {:error, :artifacts_disabled}
  end

  defp ensure_retention_enabled do
    if Config.retention_enabled?(), do: :ok, else: {:error, :artifact_retention_disabled}
  end

  defp retained_metadata(metadata) do
    metadata
    |> Map.put_new(:retention, "retained")
    |> Map.put_new(:lifecycle, "active")
    |> Map.put_new(:created_at, now())
    |> Map.put_new(:redaction_status, "metadata_only")
  end

  defp public_artifact(%{sha256: sha256, metadata: metadata} = artifact) do
    artifact
    |> Map.take([:sha256, :byte_size, :deduped?])
    |> Map.put(:artifact_uri, artifact_uri(sha256))
    |> Map.put(:metadata, metadata)
  end

  defp metadata_artifact(%{sha256: sha256} = metadata) do
    %{
      sha256: sha256,
      artifact_uri: artifact_uri(sha256),
      metadata: metadata
    }
  end

  defp maybe_read_bytes(_sha256, false, _opts), do: {:ok, nil}
  defp maybe_read_bytes(sha256, true, opts), do: Store.read(sha256, opts)

  defp delete_metadata(sha256, opts) do
    case MetadataIndex.delete(sha256, opts) do
      {:ok, deleted} -> deleted
      {:error, :not_found} -> %{sha256: sha256, deleted?: false, reason: :not_found}
      {:error, reason} -> %{sha256: sha256, deleted?: false, reason: reason}
    end
  end

  defp filter_records(records, opts, since) do
    records
    |> filter_by_metadata(:mime, Keyword.get(opts, :mime))
    |> filter_by_metadata(:origin, Keyword.get(opts, :origin))
    |> filter_by_metadata(:retention, Keyword.get(opts, :retention))
    |> filter_by_metadata(:lifecycle, Keyword.get(opts, :lifecycle))
    |> filter_by_since(since)
  end

  defp filter_by_metadata(records, _key, nil), do: records

  defp filter_by_metadata(records, key, expected) do
    Enum.filter(records, fn %{metadata: metadata} -> metadata_value(metadata, key) == expected end)
  end

  defp filter_by_since(records, nil), do: records

  defp filter_by_since(records, %DateTime{} = since) do
    Enum.filter(records, fn %{metadata: metadata} ->
      metadata
      |> metadata_value(:created_at)
      |> created_at_on_or_after?(since)
    end)
  end

  defp created_at_on_or_after?(created_at, since) when is_binary(created_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, created_at, _offset} -> DateTime.compare(created_at, since) in [:eq, :gt]
      {:error, _reason} -> false
    end
  end

  defp created_at_on_or_after?(_created_at, _since), do: false

  defp limit_records(records, nil), do: records

  defp limit_records(records, limit) when is_integer(limit) and limit > 0 do
    Enum.take(records, limit)
  end

  defp limit_records(records, _limit), do: records

  defp list_source_records(opts) do
    case Keyword.get(opts, :thread_id) do
      nil -> MetadataIndex.list(opts)
      "" -> MetadataIndex.list(opts)
      thread_id -> list_thread_metadata(thread_id, opts)
    end
  end

  defp list_thread_metadata(thread_id, opts) do
    with {:ok, user_id} <- required_opt(opts, :user_id, :missing_user_id),
         {:ok, sha256s} <- ThreadLinks.artifact_sha256s_for_thread(user_id, thread_id, opts) do
      read_metadata_records(sha256s, opts)
    end
  end

  defp read_metadata_records(sha256s, opts) do
    Enum.reduce_while(sha256s, {:ok, []}, fn sha256, {:ok, acc} ->
      case MetadataIndex.lookup(sha256, opts) do
        {:ok, metadata} -> {:cont, {:ok, [metadata | acc]}}
        {:error, :not_found} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp required_opt(opts, key, error) do
    opts
    |> Keyword.get(key)
    |> case do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> {:error, error}
          value -> {:ok, value}
        end

      value when not is_nil(value) ->
        {:ok, to_string(value)}

      nil ->
        {:error, error}
    end
  end

  defp normalize_since(value) when value in [nil, ""], do: {:ok, nil}
  defp normalize_since(%DateTime{} = value), do: {:ok, value}

  defp normalize_since(value) when is_binary(value) do
    value = String.trim(value)

    with {:error, _datetime_reason} <- DateTime.from_iso8601(value),
         {:error, _date_reason} <- Date.from_iso8601(value) do
      {:error, {:invalid_since, value}}
    else
      {:ok, %DateTime{} = datetime, _offset} ->
        {:ok, datetime}

      {:ok, %Date{} = date} ->
        DateTime.new(date, ~T[00:00:00], "Etc/UTC")
    end
  end

  defp normalize_since(value), do: {:error, {:invalid_since, value}}

  defp metadata_value(metadata, key) do
    Map.get(metadata, key, Map.get(metadata, Atom.to_string(key)))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
