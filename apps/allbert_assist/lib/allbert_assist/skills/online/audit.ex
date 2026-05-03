defmodule AllbertAssist.Skills.Online.Audit do
  @moduledoc """
  Static audit for fetched online skill details.

  The audit treats scripts, package manifests, and external links as inert
  metadata. It never executes or installs anything.
  """

  @credential_pattern ~r/(api[_-]?key|token|password|secret|credential)/i
  @external_link_pattern ~r/https?:\/\/[^\s)]+/i
  @package_manifest_names ~w[package.json package-lock.json pnpm-lock.yaml yarn.lock requirements.txt pyproject.toml mix.exs]

  def run(detail) when is_map(detail) do
    files = Map.get(detail, :files, %{})
    skill_md = Map.get(detail, :skill_md) || Map.get(files, "SKILL.md")
    parsed = parse_skill_md(skill_md)
    file_paths = Map.keys(files)
    warnings = warnings(skill_md, file_paths, parsed)

    %{
      status: if(parsed.valid?, do: :passed, else: :failed),
      import_eligible?: parsed.valid?,
      skill_md_valid?: parsed.valid?,
      skill_name: parsed.name,
      description: parsed.description,
      license: parsed.license,
      resources: resource_inventory(file_paths),
      scripts_present?: Enum.any?(file_paths, &String.starts_with?(&1, "scripts/")),
      package_manifests: Enum.filter(file_paths, &(Path.basename(&1) in @package_manifest_names)),
      external_links: external_links(skill_md),
      credential_warnings: credential_warnings(skill_md),
      source_url: Map.get(detail, :source_url),
      digest: digest(files),
      warnings: warnings,
      diagnostics: parsed.diagnostics
    }
  end

  defp parse_skill_md(nil) do
    %{
      valid?: false,
      name: nil,
      description: nil,
      license: nil,
      diagnostics: [%{severity: :error, code: :missing_skill_md}]
    }
  end

  defp parse_skill_md(skill_md) when is_binary(skill_md) do
    case Regex.run(~r/\A---[ \t]*\r?\n(?<frontmatter>.*?)(?:\r?\n)---/s, skill_md,
           capture: ["frontmatter"]
         ) do
      [frontmatter] ->
        frontmatter_attrs(frontmatter)

      _match ->
        %{
          valid?: false,
          name: nil,
          description: nil,
          license: nil,
          diagnostics: [%{severity: :error, code: :missing_frontmatter}]
        }
    end
  end

  defp frontmatter_attrs(frontmatter) do
    case YamlElixir.read_from_string(frontmatter) do
      {:ok, %{} = attrs} ->
        name = Map.get(attrs, "name")
        description = Map.get(attrs, "description")
        missing = Enum.reject(["name", "description"], &present_string?(Map.get(attrs, &1)))

        %{
          valid?: missing == [],
          name: name,
          description: description,
          license: Map.get(attrs, "license"),
          diagnostics:
            Enum.map(missing, &%{severity: :error, code: :missing_required_field, field: &1})
        }

      {:ok, _other} ->
        %{
          valid?: false,
          name: nil,
          description: nil,
          license: nil,
          diagnostics: [%{severity: :error, code: :frontmatter_not_map}]
        }

      {:error, reason} ->
        %{
          valid?: false,
          name: nil,
          description: nil,
          license: nil,
          diagnostics: [%{severity: :error, code: :invalid_yaml, value: inspect(reason)}]
        }
    end
  end

  defp warnings(skill_md, file_paths, parsed) do
    []
    |> maybe_warn(not parsed.valid?, :invalid_skill_md)
    |> maybe_warn(Enum.any?(file_paths, &String.starts_with?(&1, "scripts/")), :scripts_present)
    |> maybe_warn(
      Enum.any?(file_paths, &(Path.basename(&1) in @package_manifest_names)),
      :package_manifest_present
    )
    |> maybe_warn(external_links(skill_md) != [], :external_links_present)
    |> maybe_warn(credential_warnings(skill_md) != [], :credential_language_present)
  end

  defp maybe_warn(warnings, true, code), do: [code | warnings]
  defp maybe_warn(warnings, false, _code), do: warnings

  defp resource_inventory(file_paths) do
    Enum.flat_map(file_paths, fn path ->
      cond do
        String.starts_with?(path, "scripts/") -> [%{path: path, kind: :script}]
        String.starts_with?(path, "references/") -> [%{path: path, kind: :reference}]
        String.starts_with?(path, "assets/") -> [%{path: path, kind: :asset}]
        true -> []
      end
    end)
  end

  defp external_links(nil), do: []

  defp external_links(text) do
    @external_link_pattern
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(&String.trim_trailing(&1, "."))
    |> Enum.uniq()
  end

  defp credential_warnings(nil), do: []

  defp credential_warnings(text) do
    if Regex.match?(@credential_pattern, text), do: [:credential_language_present], else: []
  end

  defp digest(files) do
    files
    |> Enum.sort_by(fn {path, _content} -> path end)
    |> Enum.map_join("\n", fn {path, content} -> "#{path}\n#{content}" end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""
end
