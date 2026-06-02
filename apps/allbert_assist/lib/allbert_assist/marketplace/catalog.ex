defmodule AllbertAssist.Marketplace.Catalog do
  @moduledoc """
  Marketplace Lite shipped catalog reader and validator.
  """

  alias AllbertAssist.Marketplace.Bundle
  alias AllbertAssist.Marketplace.Diagnostic
  alias AllbertAssist.Marketplace.Provenance
  alias AllbertAssist.Settings

  @index_file "index.json"
  @allowed_index_keys ~w[
    schema_version
    catalog_version
    source
    generated_at
    source_git_commit
    entries
  ]
  @required_index_keys @allowed_index_keys
  @allowed_entry_keys ~w[
    id
    version
    kind
    name
    description
    author
    license
    bundle_path
    bundle_hash
    provenance
    tags
  ]
  @required_entry_keys @allowed_entry_keys
  @entry_id_pattern ~r/^[a-z0-9][a-z0-9_-]*\/[a-z0-9][a-z0-9_-]*$/
  @version_pattern ~r/^\d+\.\d+\.\d+$/
  @bundle_hash_pattern ~r/^sha256:[0-9a-f]{64}$/
  @kinds ~w[skill template plugin_index]

  @type catalog :: map()

  @spec read(keyword()) :: {:ok, catalog()} | {:error, map()}
  def read(opts \\ []) do
    index_path = index_path(opts)

    with {:ok, catalog} <- read_index(index_path),
         :ok <- validate_index(catalog, opts),
         {:ok, catalog} <- verify_entries(catalog, opts),
         :ok <- maybe_mirror(index_path, opts) do
      {:ok,
       catalog
       |> Map.put("catalog_root", Path.dirname(index_path))
       |> Map.put("index_path", index_path)}
    end
  end

  @spec list_entries(keyword()) :: {:ok, [map()]} | {:error, map()}
  def list_entries(opts \\ []) do
    with {:ok, catalog} <- read(opts) do
      {:ok, catalog["entries"]}
    end
  end

  @spec get_entry(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def get_entry(entry_id, opts \\ []) do
    version = Keyword.get(opts, :version)

    with :ok <- validate_entry_id_value(entry_id, "/entry_id"),
         {:ok, entries} <- list_entries(opts) do
      entries
      |> Enum.filter(&(&1["id"] == entry_id))
      |> select_version(version)
      |> case do
        nil ->
          {:error,
           Diagnostic.new(
             :catalog_entry_not_found,
             :entry_not_found,
             "marketplace entry not found",
             pointer: "/entry_id",
             details: %{entry_id: entry_id, version: version}
           )}

        entry ->
          {:ok, entry}
      end
    end
  end

  def inspect_entry(entry_id, opts \\ []) do
    with {:ok, entry} <- get_entry(entry_id, opts),
         {:ok, manifest} <- Bundle.read_and_verify(entry, catalog_root(opts), opts) do
      {:ok,
       %{
         entry: entry,
         bundle_manifest: manifest,
         installable?: Bundle.installable_kind?(entry["kind"])
       }}
    end
  end

  @spec catalog_root(keyword()) :: String.t()
  def catalog_root(opts \\ []), do: opts |> index_path() |> Path.dirname()

  @spec index_path(keyword()) :: String.t()
  def index_path(opts \\ []) do
    opts
    |> Keyword.get(:index_path, default_index_path())
    |> Path.expand()
  end

  @spec default_index_path() :: String.t()
  def default_index_path do
    :allbert_assist
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("marketplace/#{@index_file}")
  end

  defp read_index(index_path) do
    with true <-
           File.regular?(index_path) ||
             {:error, diagnostic(:catalog_missing, :missing_index, "/")},
         {:ok, body} <- File.read(index_path),
         {:ok, decoded} <- Jason.decode(body),
         true <- is_map(decoded) || {:error, diagnostic(:catalog_invalid, :expected_object, "/")} do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         diagnostic(:catalog_invalid, :invalid_json, "/",
           details: %{message: Exception.message(error)}
         )}

      {:error, %{} = diagnostic} ->
        {:error, diagnostic}

      {:error, reason} ->
        {:error,
         diagnostic(:catalog_invalid, :read_failed, "/", details: %{reason: inspect(reason)})}
    end
  end

  defp validate_index(index, opts) do
    with :ok <- reject_unknown_index_keys(index),
         :ok <- require_index_keys(index),
         :ok <- validate_schema_version(index),
         :ok <- validate_source(index),
         :ok <- validate_generated_at(index),
         :ok <- validate_entries(index["entries"]),
         :ok <- validate_duplicate_ids(index["entries"]) do
      validate_entry_bundles(index["entries"], Path.dirname(index_path(opts)), opts)
    end
  end

  defp verify_entries(index, opts) do
    entries =
      index["entries"]
      |> Enum.map(fn entry ->
        entry
        |> Map.put("marketplace_uri", marketplace_uri(entry["id"]))
        |> Map.put("bundle_dir", bundle_dir_text(entry, Path.dirname(index_path(opts))))
      end)

    {:ok, Map.put(index, "entries", entries)}
  end

  defp validate_entry_bundles(entries, catalog_root, opts) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {entry, _index}, :ok ->
      case Bundle.read_and_verify(entry, catalog_root, opts) do
        {:ok, _manifest} -> {:cont, :ok}
        {:error, diagnostic} -> {:halt, {:error, diagnostic}}
      end
    end)
  end

  defp reject_unknown_index_keys(index) do
    case Enum.find(Map.keys(index), &(&1 not in @allowed_index_keys)) do
      nil -> :ok
      key -> {:error, diagnostic(:catalog_invalid, :unknown_key, pointer(key))}
    end
  end

  defp require_index_keys(index) do
    case Enum.find(@required_index_keys, &(not Map.has_key?(index, &1))) do
      nil -> :ok
      key -> {:error, diagnostic(:catalog_invalid, :missing_required_field, pointer(key))}
    end
  end

  defp validate_schema_version(%{"schema_version" => 1}), do: :ok

  defp validate_schema_version(%{"schema_version" => version}) do
    {:error,
     diagnostic(
       :catalog_schema_version_unsupported,
       :unsupported_schema_version,
       "/schema_version",
       details: %{schema_version: version}
     )}
  end

  defp validate_source(%{"source" => "shipped"}), do: :ok

  defp validate_source(%{"source" => source}) do
    {:error,
     diagnostic(:catalog_invalid, :unsupported_source, "/source", details: %{source: source})}
  end

  defp validate_generated_at(%{"generated_at" => generated_at}) when is_binary(generated_at) do
    case DateTime.from_iso8601(generated_at) do
      {:ok, _dt, _offset} ->
        :ok

      {:error, _reason} ->
        {:error, diagnostic(:catalog_invalid, :invalid_generated_at, "/generated_at")}
    end
  end

  defp validate_generated_at(_index),
    do: {:error, diagnostic(:catalog_invalid, :invalid_generated_at, "/generated_at")}

  defp validate_entries(entries) when is_list(entries) and entries != [] do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {entry, index}, :ok ->
      case validate_entry(entry, index) do
        :ok -> {:cont, :ok}
        {:error, diagnostic} -> {:halt, {:error, diagnostic}}
      end
    end)
  end

  defp validate_entries(_entries),
    do: {:error, diagnostic(:catalog_invalid, :invalid_entries, "/entries")}

  defp validate_entry(entry, index) when is_map(entry) do
    with :ok <- reject_unknown_entry_keys(entry, index),
         :ok <- require_entry_keys(entry, index),
         :ok <- validate_entry_id_value(entry["id"], pointer("entries", index, "id")),
         :ok <- validate_version(entry["version"], pointer("entries", index, "version")),
         :ok <- validate_kind(entry["kind"], pointer("entries", index, "kind")),
         :ok <-
           validate_bundle_hash(entry["bundle_hash"], pointer("entries", index, "bundle_hash")),
         :ok <- validate_tags(entry["tags"], pointer("entries", index, "tags")) do
      Provenance.validate(entry["provenance"], ["entries", index, "provenance"])
    end
  end

  defp validate_entry(_entry, index),
    do: {:error, diagnostic(:catalog_invalid, :expected_object, pointer("entries", index))}

  defp reject_unknown_entry_keys(entry, index) do
    case Enum.find(Map.keys(entry), &(&1 not in @allowed_entry_keys)) do
      nil -> :ok
      key -> {:error, diagnostic(:catalog_invalid, :unknown_key, pointer("entries", index, key))}
    end
  end

  defp require_entry_keys(entry, index) do
    case Enum.find(@required_entry_keys, &(not Map.has_key?(entry, &1))) do
      nil ->
        :ok

      key ->
        {:error,
         diagnostic(:catalog_invalid, :missing_required_field, pointer("entries", index, key))}
    end
  end

  defp validate_entry_id_value(value, pointer) when is_binary(value) do
    if Regex.match?(@entry_id_pattern, value),
      do: :ok,
      else: {:error, diagnostic(:catalog_invalid, :invalid_entry_id, pointer)}
  end

  defp validate_entry_id_value(_value, pointer),
    do: {:error, diagnostic(:catalog_invalid, :invalid_entry_id, pointer)}

  defp validate_version(value, pointer) when is_binary(value) do
    if Regex.match?(@version_pattern, value),
      do: :ok,
      else: {:error, diagnostic(:catalog_invalid, :invalid_version, pointer)}
  end

  defp validate_version(_value, pointer),
    do: {:error, diagnostic(:catalog_invalid, :invalid_version, pointer)}

  defp validate_kind(kind, _pointer) when kind in @kinds, do: :ok

  defp validate_kind(kind, pointer) do
    {:error, diagnostic(:catalog_invalid, :unsupported_kind, pointer, details: %{kind: kind})}
  end

  defp validate_bundle_hash(value, pointer) when is_binary(value) do
    if Regex.match?(@bundle_hash_pattern, value),
      do: :ok,
      else: {:error, diagnostic(:catalog_invalid, :invalid_bundle_hash, pointer)}
  end

  defp validate_bundle_hash(_value, pointer),
    do: {:error, diagnostic(:catalog_invalid, :invalid_bundle_hash, pointer)}

  defp validate_tags(tags, pointer) when is_list(tags) do
    if Enum.all?(tags, &is_binary/1),
      do: :ok,
      else: {:error, diagnostic(:catalog_invalid, :invalid_tags, pointer)}
  end

  defp validate_tags(_tags, pointer),
    do: {:error, diagnostic(:catalog_invalid, :invalid_tags, pointer)}

  defp validate_duplicate_ids(entries) do
    entries
    |> Enum.map(& &1["id"])
    |> Enum.frequencies()
    |> Enum.find(fn {_id, count} -> count > 1 end)
    |> case do
      nil ->
        :ok

      {id, _count} ->
        {:error,
         diagnostic(:catalog_invalid, :duplicate_entry_id, "/entries", details: %{entry_id: id})}
    end
  end

  defp select_version([], _version), do: nil

  defp select_version(entries, nil) do
    Enum.max_by(entries, &semver_tuple(&1["version"]))
  end

  defp select_version(entries, version), do: Enum.find(entries, &(&1["version"] == version))

  defp semver_tuple(version) do
    version
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end

  defp maybe_mirror(index_path, opts) do
    if Keyword.get(opts, :mirror?, true) do
      mirror_index(index_path, opts)
    else
      :ok
    end
  end

  defp mirror_index(index_path, opts) do
    case mirror_path_result(opts) do
      {:ok, target} ->
        write_mirror(index_path, target)

      {:error, diagnostic} ->
        {:error, diagnostic}
    end
  end

  defp write_mirror(index_path, target) do
    with :ok <- File.mkdir_p(Path.dirname(target)),
         {:ok, body} <- File.read(index_path) do
      tmp = target <> ".tmp"
      File.write!(tmp, body)
      File.rename!(tmp, target)
      :ok
    else
      {:error, reason} ->
        {:error,
         diagnostic(:catalog_invalid, :mirror_failed, "/",
           details: %{reason: inspect(reason), target: target}
         )}
    end
  end

  @spec mirror_path(keyword()) :: String.t()
  def mirror_path(opts \\ []) do
    case mirror_path_result(opts) do
      {:ok, path} -> path
      {:error, _diagnostic} -> default_mirror_path(opts)
    end
  end

  defp mirror_path_result(opts) do
    home = opts |> Keyword.get(:home, AllbertAssist.Paths.home()) |> Path.expand()

    cache_dir =
      opts
      |> Keyword.get(:cache_path, read_cache_path_setting())
      |> String.replace("<ALLBERT_HOME>", home)
      |> Path.expand()

    if within?(cache_dir, home) do
      {:ok, Path.join(cache_dir, @index_file)}
    else
      {:error,
       diagnostic(
         :catalog_invalid,
         :cache_path_outside_allbert_home,
         "/marketplace/catalog/cache_path",
         details: %{cache_path: cache_dir, home: home}
       )}
    end
  end

  defp read_cache_path_setting do
    case Settings.get("marketplace.catalog.cache_path") do
      {:ok, path} when is_binary(path) -> path
      _other -> "<ALLBERT_HOME>/marketplace/cache"
    end
  end

  defp default_mirror_path(opts) do
    opts
    |> Keyword.get(:home, AllbertAssist.Paths.home())
    |> Path.join("marketplace/cache/index.json")
  end

  defp marketplace_uri(entry_id), do: "marketplace://entry/#{entry_id}"

  defp bundle_dir_text(entry, root) do
    case Bundle.bundle_dir(entry, root) do
      {:ok, path} -> path
      {:error, _diagnostic} -> nil
    end
  end

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp pointer(key), do: Diagnostic.pointer([key])
  defp pointer(key, index), do: Diagnostic.pointer([key, index])
  defp pointer(key, index, field), do: Diagnostic.pointer([key, index, field])

  defp diagnostic(category, code, pointer, opts \\ []) do
    Diagnostic.new(category, code, message(code), Keyword.put(opts, :pointer, pointer))
  end

  defp message(:missing_index), do: "marketplace index.json is missing"
  defp message(:invalid_json), do: "marketplace index JSON is invalid"
  defp message(:expected_object), do: "marketplace index entry must be an object"
  defp message(:read_failed), do: "marketplace index could not be read"
  defp message(:unknown_key), do: "marketplace index contains an unknown key"
  defp message(:missing_required_field), do: "marketplace index is missing a required field"
  defp message(:unsupported_schema_version), do: "marketplace schema_version is unsupported"
  defp message(:unsupported_source), do: "marketplace source must be shipped"
  defp message(:invalid_generated_at), do: "marketplace generated_at must be ISO-8601"
  defp message(:invalid_entries), do: "marketplace entries must be a non-empty list"
  defp message(:invalid_entry_id), do: "marketplace entry id is invalid"
  defp message(:invalid_version), do: "marketplace entry version is invalid"
  defp message(:unsupported_kind), do: "marketplace entry kind is unsupported"
  defp message(:invalid_bundle_hash), do: "marketplace bundle_hash is invalid"
  defp message(:invalid_tags), do: "marketplace tags must be strings"
  defp message(:duplicate_entry_id), do: "marketplace entry id is duplicated"

  defp message(:cache_path_outside_allbert_home),
    do: "marketplace cache_path must remain under Allbert Home"

  defp message(:mirror_failed), do: "marketplace mirror write failed"
end
