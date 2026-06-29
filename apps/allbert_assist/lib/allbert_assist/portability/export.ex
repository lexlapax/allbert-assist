defmodule AllbertAssist.Portability.Export do
  @moduledoc """
  Builds a redacted, dry-run importable Allbert Home export envelope.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Portability.Envelope
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.Settings.VersionContract

  @secret_paths MapSet.new([
                  "settings/secrets.yml.enc",
                  "settings/.settings_key"
                ])

  @excluded_prefixes ~w(cache/ tmp/)
  @secret_ref_pattern ~r/^secret:\/\/[A-Za-z0-9_\/.-]+$/

  @doc "Build an export envelope for the current Allbert Home."
  @spec build(keyword()) :: {:ok, map()} | {:error, term()}
  def build(opts \\ []) do
    home = Keyword.get_lazy(opts, :home, &Paths.home/0)

    with {:ok, user_settings} <- Store.read_user_settings() do
      fragments = VersionContract.inventory(user_settings: user_settings)
      files = file_manifest(home)
      secret_refs = secret_references(user_settings)

      {:ok,
       %{
         "envelope_version" => Envelope.envelope_version(),
         "exported_at" =>
           DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
         "allbert_version" => allbert_version(),
         "source_home" => Path.expand(home),
         "redaction" => %{
           "settings" =>
             "sensitive values redacted; secret refs preserved only in secret_references",
           "files" => "hashes only; file contents are not embedded",
           "secret_values_exported" => false
         },
         "settings" => %{
           "user_settings" => redact_settings(user_settings),
           "fragments" => fragments,
           "version_contract" => VersionContract.status(user_settings: user_settings)
         },
         "secret_references" => secret_refs,
         "manifest" => %{
           "home" => %{
             "file_count" => Enum.count(files, &(&1["included"] == true)),
             "excluded_count" => Enum.count(files, &(&1["included"] == false)),
             "domains" => domain_counts(files),
             "files" => files
           },
           "inert_import_invariants" => %{
             "dry_run_only" => true,
             "self_improvement_suggestions" => "inert",
             "voice_capture" => "not_armed",
             "vision_capture" => "not_armed"
           }
         }
       }}
    end
  end

  defp file_manifest(home) do
    home = Path.expand(home)

    if File.dir?(home) do
      home
      |> regular_files()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&file_entry(home, &1))
      |> Enum.sort_by(& &1["path"])
    else
      []
    end
  end

  defp regular_files(root) do
    root
    |> File.ls()
    |> case do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(root, entry)

          cond do
            File.dir?(path) -> regular_files(path)
            File.regular?(path) -> [path]
            true -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp file_entry(home, path) do
    relative = relative_path(home, path)
    domain = domain(relative)

    if excluded_file?(relative) do
      %{
        "path" => relative,
        "domain" => domain,
        "included" => false,
        "reason" => exclusion_reason(relative)
      }
    else
      bytes = File.stat!(path).size

      %{
        "path" => relative,
        "domain" => domain,
        "included" => true,
        "bytes" => bytes,
        "sha256" => sha256_file(path)
      }
    end
  end

  defp excluded_file?(relative) do
    MapSet.member?(@secret_paths, relative) or
      Enum.any?(@excluded_prefixes, &String.starts_with?(relative, &1))
  end

  defp exclusion_reason(relative) do
    cond do
      MapSet.member?(@secret_paths, relative) -> "secret_store_excluded"
      String.starts_with?(relative, "cache/") -> "cache_excluded"
      String.starts_with?(relative, "tmp/") -> "tmp_excluded"
      true -> "excluded"
    end
  end

  defp relative_path(home, path) do
    path
    |> Path.expand()
    |> Path.relative_to(home)
  end

  defp domain(relative) do
    case String.split(relative, "/", parts: 2) do
      ["settings" | _] -> "settings"
      ["memory" | _] -> "memory"
      ["skills" | _] -> "skills"
      ["confirmations" | _] -> "confirmations"
      ["execution" | _] -> "execution"
      ["sandbox" | _] -> "sandbox"
      ["dynamic_plugins" | _] -> "dynamic_plugins"
      ["drafts" | _] -> "self_improvement"
      ["external" | _] -> "external_services"
      ["mcp" | _] -> "mcp"
      ["artifacts" | _] -> "artifacts"
      ["audio" | _] -> "media"
      ["images" | _] -> "media"
      ["generated_images" | _] -> "media"
      ["workspace" | _] -> "workspace"
      ["themes" | _] -> "themes"
      ["db" | _] -> "runtime_db"
      ["plugins" | _] -> "plugins"
      ["cache" | _] -> "cache"
      ["tmp" | _] -> "tmp"
      _other -> "other"
    end
  end

  defp domain_counts(files) do
    files
    |> Enum.group_by(& &1["domain"])
    |> Map.new(fn {domain, entries} ->
      included = Enum.count(entries, &(&1["included"] == true))
      excluded = Enum.count(entries, &(&1["included"] == false))

      {domain, %{"included" => included, "excluded" => excluded}}
    end)
  end

  defp sha256_file(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp secret_references(settings) do
    settings
    |> collect_secret_refs()
    |> Enum.sort()
    |> Enum.map(fn ref ->
      %{
        "ref" => ref,
        "status" => Secrets.status(ref) |> to_string()
      }
    end)
  end

  defp collect_secret_refs(term),
    do: term |> collect_secret_refs(MapSet.new()) |> MapSet.to_list()

  defp collect_secret_refs(value, refs) when is_binary(value) do
    if secret_ref?(value), do: MapSet.put(refs, value), else: refs
  end

  defp collect_secret_refs(%{} = map, refs) do
    Enum.reduce(map, refs, fn {_key, value}, acc -> collect_secret_refs(value, acc) end)
  end

  defp collect_secret_refs(list, refs) when is_list(list) do
    Enum.reduce(list, refs, &collect_secret_refs/2)
  end

  defp collect_secret_refs(_term, refs), do: refs

  defp redact_settings(settings), do: redact_settings(settings, [])

  defp redact_settings(%{} = map, path) do
    Map.new(map, fn {key, value} ->
      {key, redact_settings(value, path ++ [to_string(key)])}
    end)
  end

  defp redact_settings(list, path) when is_list(list) do
    Enum.map(list, &redact_settings(&1, path))
  end

  defp redact_settings(value, path) when is_binary(value) do
    cond do
      secret_ref?(value) -> Redactor.redact(value)
      sensitive_path?(path) -> "[REDACTED]"
      true -> Redactor.redact(value)
    end
  end

  defp redact_settings(value, _path), do: value

  defp secret_ref?(value), do: Regex.match?(@secret_ref_pattern, value)

  defp sensitive_path?(path) do
    path
    |> List.last()
    |> to_string()
    |> String.downcase()
    |> then(fn key ->
      String.contains?(key, "api_key") or String.contains?(key, "token") or
        String.contains?(key, "secret") or String.contains?(key, "authorization") or
        String.contains?(key, "base_url") or String.contains?(key, "endpoint")
    end)
  end

  defp allbert_version do
    case Application.spec(:allbert_assist, :vsn) do
      nil -> "unknown"
      version -> List.to_string(version)
    end
  end
end
