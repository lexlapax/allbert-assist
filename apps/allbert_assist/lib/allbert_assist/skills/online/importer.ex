defmodule AllbertAssist.Skills.Online.Importer do
  @moduledoc """
  Disabled-by-default online skill importer.

  Writes fetched skill files under Allbert cache only, records source metadata,
  and invokes the existing parser/registry validation. It never enables,
  trusts, activates, or executes imported content.
  """

  alias AllbertAssist.Paths
  alias AllbertAssist.Skills.Parser

  @spec import(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def import(detail, audit, source) do
    if Map.get(audit, :import_eligible?) do
      do_import(detail, audit, source)
    else
      {:error, :online_skill_audit_failed}
    end
  end

  defp do_import(detail, audit, source) do
    files = Map.get(detail, :files, %{})
    candidate = Map.get(detail, :candidate, %{})
    skill_name = safe_segment(Map.get(audit, :skill_name) || Map.get(candidate, :name) || "skill")
    owner = safe_segment(Map.get(candidate, :owner) || "unknown")
    repository = safe_segment(Map.get(candidate, :repository) || "source")
    source_id = safe_segment(Map.get(source, :id) || Map.get(source, "id") || "skills_sh")

    target_root =
      Path.join([Paths.cache_root(), "skills", source_id, "#{owner}-#{repository}", skill_name])

    with :ok <- ensure_safe_files(files),
         :ok <- write_files(target_root, files),
         parser_result <- Parser.parse_dir(target_root),
         {:ok, manifest_path} <- write_manifest(detail, audit, source, target_root, parser_result) do
      {:ok,
       %{
         status: :imported_disabled,
         target_root: target_root,
         manifest_path: manifest_path,
         source_scope: :imported_cache,
         enabled?: false,
         trusted?: false,
         parser_result: parser_summary(parser_result),
         audit: audit
       }}
    end
  end

  defp ensure_safe_files(files) when is_map(files) do
    files
    |> Map.keys()
    |> Enum.find(&unsafe_path?/1)
    |> case do
      nil -> :ok
      path -> {:error, {:unsafe_import_path, path}}
    end
  end

  defp ensure_safe_files(_files), do: {:error, :invalid_import_files}

  defp write_files(target_root, files) do
    File.mkdir_p!(target_root)

    Enum.each(files, fn {relative_path, content} ->
      path = Path.join(target_root, relative_path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end)

    :ok
  rescue
    exception -> {:error, {:online_skill_write_failed, Exception.message(exception)}}
  end

  defp write_manifest(detail, audit, source, target_root, parser_result) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    source_id = safe_segment(Map.get(source, :id) || Map.get(source, "id") || "skills_sh")
    id = detail |> Map.get(:id, "unknown") |> safe_segment()
    manifest_dir = Path.join([Paths.online_skill_sources_root(), source_id])
    manifest_path = Path.join(manifest_dir, "#{id}.json")

    manifest = %{
      source: source,
      source_id: Map.get(detail, :id),
      source_url: Map.get(detail, :source_url),
      digest: Map.get(audit, :digest),
      fetched_at: Map.get(detail, :fetched_at) || now,
      imported_at: now,
      target_root: target_root,
      enabled?: false,
      trusted?: false,
      audit: audit,
      parser: parser_summary(parser_result)
    }

    File.mkdir_p!(manifest_dir)
    File.write!(manifest_path, Jason.encode!(manifest, pretty: true))
    {:ok, manifest_path}
  rescue
    exception -> {:error, {:online_skill_manifest_write_failed, Exception.message(exception)}}
  end

  defp parser_summary({:ok, spec}) do
    %{status: :ok, name: spec.name, diagnostics: spec.diagnostics}
  end

  defp parser_summary({:error, diagnostics}) do
    %{status: :error, diagnostics: diagnostics}
  end

  defp unsafe_path?(path) do
    path = to_string(path)

    path == "" or Path.type(path) == :absolute or String.contains?(path, ["..", "\\"]) or
      path |> Path.split() |> Enum.any?(&String.starts_with?(&1, "."))
  end

  defp safe_segment(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      segment -> segment
    end
  end
end
