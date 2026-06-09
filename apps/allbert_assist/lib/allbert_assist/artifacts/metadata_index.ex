defmodule AllbertAssist.Artifacts.MetadataIndex do
  @moduledoc """
  Markdown-first metadata index for artifacts.

  The durable index is a sidecar markdown file per artifact under the artifacts
  root. This module is a plain storage module with an ETS lookup cache because
  the cache is derived state, not runtime authority.
  """

  alias AllbertAssist.Artifacts.Store

  @table :allbert_artifacts_metadata_index
  @allowed_keys [
    :sha256,
    :mime,
    :byte_size,
    :origin,
    :source_resource_uri,
    :created_at,
    :retention,
    :redaction_status,
    :lifecycle,
    :provenance
  ]
  @allowed_key_strings Enum.map(@allowed_keys, &Atom.to_string/1)

  @type allowed_key ::
          :sha256
          | :mime
          | :byte_size
          | :origin
          | :source_resource_uri
          | :created_at
          | :retention
          | :redaction_status
          | :lifecycle
          | :provenance

  @doc "Return the metadata fields persisted by the markdown sidecar index."
  @spec allowed_keys() :: [allowed_key(), ...]
  def allowed_keys, do: @allowed_keys

  @doc "Write allow-listed metadata for an artifact SHA-256."
  @spec write(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def write(metadata, opts \\ []) when is_map(metadata) do
    with {:ok, sha256} <- fetch_sha256(metadata),
         :ok <- validate_sha256(sha256),
         normalized <- normalize(Map.put(metadata, :sha256, sha256)),
         {:ok, body} <- encode_markdown(normalized),
         path <- sidecar_path!(sha256, opts),
         :ok <- write_atomic(path, body) do
      cache_put(Store.root(opts), normalized)
      {:ok, normalized}
    else
      {:error, %Jason.EncodeError{} = error} -> {:error, {:invalid_metadata, error}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Read metadata for an artifact SHA-256 from its markdown sidecar."
  @spec read(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(sha256, opts \\ []) do
    with :ok <- validate_sha256(sha256),
         {:ok, body} <- read_sidecar(sha256, opts),
         {:ok, metadata} <- decode_markdown(body),
         {:ok, normalized_sha256} <- fetch_sha256(metadata),
         :ok <- validate_matching_sha256(sha256, normalized_sha256),
         normalized <- normalize(Map.put(metadata, :sha256, sha256)) do
      cache_put(Store.root(opts), normalized)
      {:ok, normalized}
    end
  end

  @doc "Lookup metadata by SHA-256, preferring the in-memory cache."
  @spec lookup(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def lookup(sha256, opts \\ []) do
    with :ok <- validate_sha256(sha256) do
      root = Store.root(opts)

      case :ets.lookup(table(), {root, sha256}) do
        [{{^root, ^sha256}, metadata}] -> {:ok, metadata}
        [] -> read(sha256, opts)
      end
    end
  end

  @doc "List persisted metadata records from the sidecar index."
  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(opts \\ []) do
    opts
    |> index_root()
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      sha256 = Path.basename(path, ".md")

      case read(sha256, opts) do
        {:ok, metadata} -> {:cont, {:ok, [metadata | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Return a sidecar path when the SHA-256 is valid."
  @spec sidecar_path(String.t(), keyword()) :: {:ok, String.t()} | {:error, :invalid_sha256}
  def sidecar_path(sha256, opts \\ []) do
    if Store.valid_sha256?(sha256) do
      {:ok,
       Path.join([
         index_root(opts),
         String.slice(sha256, 0, 2),
         String.slice(sha256, 2, 2),
         "#{sha256}.md"
       ])}
    else
      {:error, :invalid_sha256}
    end
  end

  @doc "Return a sidecar path or raise when the SHA-256 is invalid."
  @spec sidecar_path!(String.t(), keyword()) :: String.t()
  def sidecar_path!(sha256, opts \\ []) do
    case sidecar_path(sha256, opts) do
      {:ok, path} -> path
      {:error, reason} -> raise ArgumentError, "invalid artifact sha256: #{inspect(reason)}"
    end
  end

  @doc "Clear the lookup cache. Intended for tests and index rebuild boundaries."
  @spec reset_cache!() :: :ok
  def reset_cache! do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _table ->
        :ets.delete_all_objects(@table)
        :ok
    end
  end

  defp read_sidecar(sha256, opts) do
    case sidecar_path(sha256, opts) do
      {:ok, path} ->
        case File.read(path) do
          {:ok, body} -> {:ok, body}
          {:error, :enoent} -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_sha256(metadata) do
    case fetch_metadata(metadata, :sha256) do
      nil -> {:error, :missing_sha256}
      sha256 when is_binary(sha256) -> {:ok, sha256}
      _sha256 -> {:error, :invalid_sha256}
    end
  end

  defp validate_sha256(sha256) do
    if Store.valid_sha256?(sha256), do: :ok, else: {:error, :invalid_sha256}
  end

  defp validate_matching_sha256(expected, actual) do
    if expected == actual, do: :ok, else: {:error, :sha256_mismatch}
  end

  defp normalize(metadata) do
    Map.new(@allowed_keys, fn key -> {key, fetch_metadata(metadata, key)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp fetch_metadata(metadata, key) do
    case Map.fetch(metadata, key) do
      {:ok, value} -> value
      :error -> Map.get(metadata, Atom.to_string(key))
    end
  end

  defp encode_markdown(metadata) do
    case Jason.encode(stringify_keys(metadata), pretty: true) do
      {:ok, json} ->
        {:ok,
         """
         # Artifact #{metadata.sha256}

         ```json
         #{json}
         ```
         """}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_markdown(body) do
    case Regex.run(~r/```json\s*(.*?)\s*```/s, body, capture: :all_but_first) do
      [json] -> decode_json(json)
      nil -> {:error, :missing_metadata_block}
    end
  end

  defp decode_json(json) do
    with {:ok, decoded} <- Jason.decode(json),
         true <- is_map(decoded) do
      {:ok, atomize_allowed_keys(decoded)}
    else
      false -> {:error, :invalid_metadata}
      {:error, reason} -> {:error, reason}
    end
  end

  defp atomize_allowed_keys(metadata) do
    Map.new(metadata, fn
      {key, value} when key in @allowed_key_strings -> {String.to_existing_atom(key), value}
      {key, value} -> {key, value}
    end)
  end

  @doc "Delete metadata for an artifact SHA-256 from the markdown sidecar index."
  @spec delete(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete(sha256, opts \\ []) do
    with :ok <- validate_sha256(sha256),
         {:ok, path} <- sidecar_path(sha256, opts) do
      case File.rm(path) do
        :ok ->
          :ets.delete(table(), {Store.root(opts), sha256})
          {:ok, %{sha256: sha256, path: path, deleted?: true}}

        {:error, :enoent} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp stringify_keys(metadata) do
    Map.new(metadata, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp write_atomic(path, body) do
    File.mkdir_p!(Path.dirname(path))
    tmp_path = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.write(tmp_path, body, [:binary]),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp index_root(opts), do: Path.join(Store.root(opts), "index")

  defp cache_put(root, metadata) do
    :ets.insert(table(), {{root, metadata.sha256}, metadata})
    :ok
  end

  defp table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      table ->
        table
    end
  end
end
