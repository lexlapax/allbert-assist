defmodule AllbertAssist.Marketplace.Bundle do
  @moduledoc """
  Bundle manifest parsing, file enumeration, and SHA-256 verification.
  """

  alias AllbertAssist.Marketplace.Diagnostic

  @manifest_file "bundle.json"
  @allowed_manifest_keys ~w[
    schema_version
    id
    version
    kind
    files
    bundle_hash
    install_target
    install_state
  ]
  @required_manifest_keys ~w[schema_version id version kind files bundle_hash]
  @installable_kinds ~w[skill template]
  @bundle_hash_pattern ~r/^sha256:[0-9a-f]{64}$/

  @spec read_and_verify(map(), String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  def read_and_verify(entry, catalog_root, opts \\ []) do
    with {:ok, bundle_dir} <- bundle_dir(entry, catalog_root),
         {:ok, manifest} <- read_manifest(bundle_dir),
         :ok <- validate_manifest(manifest, entry),
         {:ok, verification} <- verify_manifest(bundle_dir, manifest, entry) do
      {:ok,
       manifest
       |> Map.put("bundle_dir", bundle_dir)
       |> Map.put("verification", verification)
       |> maybe_put_resolved_install_target(opts)}
    end
  end

  @spec read_manifest(String.t()) :: {:ok, map()} | {:error, map()}
  def read_manifest(bundle_dir) do
    path = Path.join(bundle_dir, @manifest_file)

    with true <-
           File.regular?(path) ||
             {:error, diagnostic(:bundle_manifest_missing, :missing_manifest, "/bundle.json")},
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         true <-
           is_map(decoded) ||
             {:error, diagnostic(:bundle_manifest_invalid, :expected_object, "/")} do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         diagnostic(:bundle_manifest_invalid, :invalid_json, "/",
           details: %{message: Exception.message(error)}
         )}

      {:error, %{} = diagnostic} ->
        {:error, diagnostic}

      {:error, reason} ->
        {:error,
         diagnostic(:bundle_manifest_invalid, :read_failed, "/bundle.json",
           details: %{reason: inspect(reason)}
         )}
    end
  end

  @spec compute_hash(String.t()) :: {:ok, String.t()} | {:error, map()}
  def compute_hash(bundle_dir) do
    with {:ok, files} <- content_files(bundle_dir) do
      digest_input =
        files
        |> Enum.map(fn %{path: path, sha256: sha256} -> path <> <<0>> <> sha256 end)
        |> Enum.join("\n")

      {:ok, "sha256:" <> sha256(digest_input)}
    end
  end

  @spec content_files(String.t()) :: {:ok, [map()]} | {:error, map()}
  def content_files(bundle_dir) do
    if File.dir?(bundle_dir) do
      bundle_dir
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&relative_file(bundle_dir, &1))
      |> Enum.reject(&(&1 == @manifest_file))
      |> Enum.sort()
      |> Enum.map(fn relative ->
        sha256 = sha256_file!(Path.join(bundle_dir, relative))

        %{
          "path" => relative,
          :path => relative,
          "sha256" => sha256,
          :sha256 => sha256
        }
      end)
      |> then(&{:ok, &1})
    else
      {:error,
       diagnostic(:bundle_manifest_invalid, :bundle_dir_missing, "/bundle_path",
         details: %{path: bundle_dir}
       )}
    end
  end

  @spec bundle_dir(map(), String.t()) :: {:ok, String.t()} | {:error, map()}
  def bundle_dir(%{"bundle_path" => bundle_path}, catalog_root) when is_binary(bundle_path) do
    cond do
      Path.type(bundle_path) != :relative ->
        {:error, diagnostic(:catalog_invalid, :invalid_bundle_path, "/bundle_path")}

      not String.starts_with?(bundle_path, "bundles/") ->
        {:error, diagnostic(:catalog_invalid, :invalid_bundle_path, "/bundle_path")}

      unsafe_relative_path?(bundle_path) ->
        {:error,
         diagnostic(:catalog_invalid, :bundle_path_traversal, "/bundle_path",
           details: %{bundle_path: bundle_path}
         )}

      true ->
        root = Path.expand(catalog_root)
        path = Path.expand(bundle_path, root)

        if within?(path, root) do
          {:ok, path}
        else
          {:error,
           diagnostic(:catalog_invalid, :bundle_path_traversal, "/bundle_path",
             details: %{bundle_path: bundle_path}
           )}
        end
    end
  end

  def bundle_dir(_entry, _catalog_root),
    do: {:error, diagnostic(:catalog_invalid, :missing_required_field, "/bundle_path")}

  @spec installable_kind?(String.t()) :: boolean()
  def installable_kind?(kind), do: kind in @installable_kinds

  @spec safe_relative_path?(String.t()) :: boolean()
  def safe_relative_path?(path) when is_binary(path) do
    Path.type(path) == :relative and not unsafe_relative_path?(path)
  end

  def safe_relative_path?(_path), do: false

  defp validate_manifest(manifest, entry) do
    with :ok <- reject_unknown_keys(manifest),
         :ok <- require_keys(manifest),
         :ok <- validate_schema_version(manifest),
         :ok <- validate_entry_match(manifest, entry),
         :ok <- validate_hash_format(Map.get(manifest, "bundle_hash"), "/bundle_hash"),
         :ok <- validate_files(Map.get(manifest, "files")),
         :ok <- validate_install_fields(manifest) do
      :ok
    end
  end

  defp verify_manifest(bundle_dir, manifest, entry) do
    with {:ok, actual_files} <- content_files(bundle_dir),
         :ok <- verify_files(manifest["files"], actual_files),
         {:ok, computed_hash} <- compute_hash(bundle_dir),
         :ok <- verify_bundle_hash(computed_hash, manifest["bundle_hash"], "/bundle_hash"),
         :ok <- verify_bundle_hash(computed_hash, entry["bundle_hash"], "/entries/bundle_hash") do
      {:ok, %{bundle_hash: computed_hash, files: actual_files}}
    end
  end

  defp verify_files(expected, actual) do
    expected_map = Map.new(expected, &{Map.fetch!(&1, "path"), Map.fetch!(&1, "sha256")})
    actual_map = Map.new(actual, &{&1.path, &1.sha256})

    cond do
      Map.keys(expected_map) != Map.keys(actual_map) ->
        {:error,
         diagnostic(:bundle_manifest_invalid, :bundle_file_list_mismatch, "/files",
           details: %{expected: Map.keys(expected_map), actual: Map.keys(actual_map)}
         )}

      mismatch = Enum.find(expected_map, fn {path, sha256} -> actual_map[path] != sha256 end) ->
        {path, sha256} = mismatch

        {:error,
         diagnostic(:bundle_manifest_invalid, :bundle_file_hash_mismatch, "/files",
           details: %{path: path, expected: sha256, actual: actual_map[path]}
         )}

      true ->
        :ok
    end
  end

  defp verify_bundle_hash(computed, expected, _pointer) when computed == expected, do: :ok

  defp verify_bundle_hash(computed, expected, pointer) do
    {:error,
     diagnostic(:bundle_hash_mismatch, :bundle_hash_mismatch, pointer,
       details: %{expected: expected, actual: computed}
     )}
  end

  defp reject_unknown_keys(manifest) do
    case Enum.find(Map.keys(manifest), &(&1 not in @allowed_manifest_keys)) do
      nil -> :ok
      key -> {:error, diagnostic(:bundle_manifest_invalid, :unknown_key, pointer(key))}
    end
  end

  defp require_keys(manifest) do
    case Enum.find(@required_manifest_keys, &(not Map.has_key?(manifest, &1))) do
      nil -> :ok
      key -> {:error, diagnostic(:bundle_manifest_invalid, :missing_required_field, pointer(key))}
    end
  end

  defp validate_schema_version(%{"schema_version" => 1}), do: :ok

  defp validate_schema_version(%{"schema_version" => version}) do
    {:error,
     diagnostic(:bundle_manifest_invalid, :unsupported_schema_version, "/schema_version",
       details: %{schema_version: version}
     )}
  end

  defp validate_entry_match(manifest, entry) do
    Enum.reduce_while(~w[id version kind], :ok, fn key, :ok ->
      if manifest[key] == entry[key] do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          diagnostic(:bundle_manifest_invalid, :entry_manifest_mismatch, pointer(key),
            details: %{expected: entry[key], actual: manifest[key]}
          )}}
      end
    end)
  end

  defp validate_hash_format(value, _pointer) when is_binary(value) do
    if Regex.match?(@bundle_hash_pattern, value),
      do: :ok,
      else: {:error, diagnostic(:bundle_manifest_invalid, :invalid_bundle_hash, "/bundle_hash")}
  end

  defp validate_hash_format(_value, pointer),
    do: {:error, diagnostic(:bundle_manifest_invalid, :invalid_bundle_hash, pointer)}

  defp validate_files(files) when is_list(files) and files != [] do
    files
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {file, index}, :ok ->
      validate_file_entry(file, index)
      |> case do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_files(_files),
    do: {:error, diagnostic(:bundle_manifest_invalid, :invalid_files, "/files")}

  defp validate_file_entry(%{"path" => path, "sha256" => sha256} = file, index) do
    with :ok <- reject_unknown_file_keys(file, index),
         :ok <- validate_file_path(path, index) do
      validate_file_sha(sha256, index)
    end
  end

  defp validate_file_entry(_file, index),
    do:
      {:error,
       diagnostic(
         :bundle_manifest_invalid,
         :invalid_file_entry,
         Diagnostic.pointer(["files", index])
       )}

  defp reject_unknown_file_keys(file, index) do
    case Enum.find(Map.keys(file), &(&1 not in ~w[path sha256])) do
      nil ->
        :ok

      key ->
        {:error, diagnostic(:bundle_manifest_invalid, :unknown_key, pointer("files", index, key))}
    end
  end

  defp validate_file_path(path, index) when is_binary(path) do
    if safe_relative_path?(path) and path != @manifest_file do
      :ok
    else
      {:error,
       diagnostic(:bundle_manifest_invalid, :invalid_file_path, pointer("files", index, "path"))}
    end
  end

  defp validate_file_path(_path, index),
    do:
      {:error,
       diagnostic(:bundle_manifest_invalid, :invalid_file_path, pointer("files", index, "path"))}

  defp validate_file_sha(value, index) when is_binary(value) do
    if Regex.match?(~r/^[0-9a-f]{64}$/, value) do
      :ok
    else
      {:error,
       diagnostic(
         :bundle_manifest_invalid,
         :invalid_file_sha256,
         pointer("files", index, "sha256")
       )}
    end
  end

  defp validate_file_sha(_value, index),
    do:
      {:error,
       diagnostic(
         :bundle_manifest_invalid,
         :invalid_file_sha256,
         pointer("files", index, "sha256")
       )}

  defp validate_install_fields(%{"kind" => kind} = manifest) when kind in @installable_kinds do
    cond do
      not Map.has_key?(manifest, "install_target") ->
        {:error, diagnostic(:bundle_manifest_invalid, :missing_required_field, "/install_target")}

      manifest["install_state"] != "disabled_untrusted" ->
        {:error,
         diagnostic(:bundle_manifest_invalid, :invalid_install_state, "/install_state",
           details: %{install_state: manifest["install_state"]}
         )}

      true ->
        :ok
    end
  end

  defp validate_install_fields(%{"kind" => "plugin_index"} = manifest) do
    if Map.has_key?(manifest, "install_target") do
      {:error,
       diagnostic(
         :bundle_manifest_invalid,
         :plugin_index_install_target_forbidden,
         "/install_target"
       )}
    else
      :ok
    end
  end

  defp validate_install_fields(%{"kind" => kind}) do
    {:error, diagnostic(:catalog_invalid, :unsupported_kind, "/kind", details: %{kind: kind})}
  end

  defp maybe_put_resolved_install_target(manifest, opts) do
    case Map.get(manifest, "install_target") do
      nil -> manifest
      target -> Map.put(manifest, "resolved_install_target", resolve_token(target, opts))
    end
  end

  defp resolve_token(path, opts) do
    home = Keyword.get(opts, :home) || AllbertAssist.Paths.home()
    String.replace(path, "<ALLBERT_HOME>", home)
  end

  defp relative_file(bundle_dir, path), do: Path.relative_to(path, bundle_dir)

  defp unsafe_relative_path?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 in ["..", ".", ""]))
  end

  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp sha256_file!(path), do: path |> File.read!() |> sha256()

  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp diagnostic(category, code, pointer, opts \\ []) do
    Diagnostic.new(category, code, message(code), Keyword.put(opts, :pointer, pointer))
  end

  defp pointer(key), do: Diagnostic.pointer([key])
  defp pointer(key, index, field), do: Diagnostic.pointer([key, index, field])

  defp message(:missing_manifest), do: "bundle manifest is missing"
  defp message(:invalid_json), do: "bundle manifest JSON is invalid"
  defp message(:expected_object), do: "bundle manifest must be an object"
  defp message(:read_failed), do: "bundle manifest could not be read"
  defp message(:bundle_dir_missing), do: "bundle directory is missing"
  defp message(:invalid_bundle_path), do: "bundle_path must be relative under bundles/"
  defp message(:bundle_path_traversal), do: "bundle_path must not traverse outside catalog root"
  defp message(:unknown_key), do: "bundle manifest contains an unknown key"
  defp message(:missing_required_field), do: "bundle manifest is missing a required field"
  defp message(:unsupported_schema_version), do: "bundle manifest schema_version is unsupported"
  defp message(:entry_manifest_mismatch), do: "bundle manifest does not match catalog entry"
  defp message(:invalid_bundle_hash), do: "bundle_hash must be sha256:<64 lowercase hex>"
  defp message(:invalid_files), do: "bundle files must be a non-empty list"
  defp message(:invalid_file_entry), do: "bundle file entry is invalid"
  defp message(:invalid_file_path), do: "bundle file path is invalid"
  defp message(:invalid_file_sha256), do: "bundle file sha256 is invalid"
  defp message(:bundle_file_list_mismatch), do: "bundle file list does not match manifest"
  defp message(:bundle_file_hash_mismatch), do: "bundle file sha256 does not match manifest"
  defp message(:bundle_hash_mismatch), do: "bundle hash does not match manifest"
  defp message(:invalid_install_state), do: "install_state must be disabled_untrusted"
  defp message(:plugin_index_install_target_forbidden), do: "plugin_index entries cannot install"
  defp message(:unsupported_kind), do: "marketplace kind is unsupported"
end
