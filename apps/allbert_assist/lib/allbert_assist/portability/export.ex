defmodule AllbertAssist.Portability.Export do
  @moduledoc """
  Builds a redacted, dry-run importable Allbert Home export envelope.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Portability.Envelope
  alias AllbertAssist.Portability.SecretReferences
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.VersionContract

  @secret_paths MapSet.new([
                  "settings/secrets.yml.enc",
                  "settings/.settings_key"
                ])

  @excluded_prefixes ~w(cache/ tmp/)
  @secret_ref_pattern ~r/^secret:\/\/[A-Za-z0-9_\/.-]+$/
  @export_secret_value_patterns [
    ~r/\bAIza[0-9A-Za-z_-]{20,}\b/,
    ~r/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/
  ]
  @domain_roots %{
    "artifacts" => "artifacts",
    "audio" => "media",
    "cache" => "cache",
    "confirmations" => "confirmations",
    "db" => "runtime_db",
    "drafts" => "self_improvement",
    "dynamic_plugins" => "dynamic_plugins",
    "execution" => "execution",
    "external" => "external_services",
    "generated_images" => "media",
    "images" => "media",
    "mcp" => "mcp",
    "memory" => "memory",
    "plugins" => "plugins",
    "sandbox" => "sandbox",
    "settings" => "settings",
    "skills" => "skills",
    "themes" => "themes",
    "tmp" => "tmp",
    "workspace" => "workspace"
  }

  @doc "Build an export envelope for the current Allbert Home."
  @spec build(keyword()) :: {:ok, map()} | {:error, term()}
  def build(opts \\ []) do
    home = Keyword.get_lazy(opts, :home, &Paths.home/0)

    with {:ok, user_settings} <- Settings.read_user_settings() do
      fragments = VersionContract.inventory(user_settings: user_settings)
      files = file_manifest(home)
      secret_refs = SecretReferences.export_rows(user_settings)

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
    |> list_dir()
    |> Enum.map(&Path.join(root, &1))
    |> Enum.flat_map(&regular_file_paths/1)
  end

  defp list_dir(root) do
    case File.ls(root) do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end

  defp regular_file_paths(path) do
    cond do
      File.dir?(path) -> regular_files(path)
      File.regular?(path) -> [path]
      true -> []
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
    relative
    |> String.split("/", parts: 2)
    |> List.first()
    |> then(&Map.get(@domain_roots, &1, "other"))
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
      true -> value |> Redactor.redact() |> redact_export_secret_shapes()
    end
  end

  defp redact_settings(value, _path), do: value

  defp secret_ref?(value), do: Regex.match?(@secret_ref_pattern, value)

  defp redact_export_secret_shapes(value) do
    Enum.reduce(@export_secret_value_patterns, value, fn pattern, acc ->
      Regex.replace(pattern, acc, "[REDACTED]")
    end)
  end

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
