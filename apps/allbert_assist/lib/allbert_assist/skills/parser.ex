defmodule AllbertAssist.Skills.Parser do
  @moduledoc """
  Parser and validator for standard Agent Skill directories.

  The parser loads a required `SKILL.md`, validates required frontmatter, keeps
  optional metadata inert, and inventories bundled resources without executing
  them.
  """

  alias AllbertAssist.Skills.AgentSkillSpec
  alias AllbertAssist.Skills.Resource

  @required_fields ["name", "description"]
  @known_fields ["name", "description", "license", "compatibility", "metadata", "allowed-tools"]
  @known_allbert_metadata [
    "allbert.actions",
    "allbert.confirmation",
    "allbert.kind",
    "allbert.memory-effects",
    "allbert.permissions",
    "allbert.trace-effects",
    "allbert.version"
  ]

  @canonical_name_pattern ~r/^[a-z0-9][a-z0-9-]{1,80}$/
  @description_limit 1024
  @resource_dirs [{"scripts", :script}, {"references", :reference}, {"assets", :asset}]

  @doc """
  Parse one skill directory containing a required `SKILL.md`.
  """
  @spec parse_dir(String.t()) ::
          {:ok, AgentSkillSpec.t()} | {:error, [AgentSkillSpec.diagnostic()]}
  def parse_dir(root_path) when is_binary(root_path) do
    root_path = Path.expand(root_path)
    skill_file_path = Path.join(root_path, "SKILL.md")

    with {:ok, content} <- read_skill_file(skill_file_path),
         {:ok, frontmatter, body} <- split_frontmatter(content, skill_file_path),
         {:ok, attrs} <- parse_frontmatter(frontmatter, skill_file_path),
         :ok <- validate_required_fields(attrs, skill_file_path) do
      diagnostics = compatibility_diagnostics(attrs, root_path, skill_file_path)
      resources = inventory_resources(root_path)

      spec =
        %AgentSkillSpec{
          root_path: root_path,
          skill_file_path: skill_file_path,
          name: attrs["name"],
          description: attrs["description"],
          license: Map.get(attrs, "license"),
          compatibility: Map.get(attrs, "compatibility"),
          allowed_tools: allowed_tools(attrs, skill_file_path),
          metadata: metadata(attrs, skill_file_path),
          external_fields: Map.drop(attrs, @known_fields),
          body: body,
          resources: resources,
          diagnostics:
            diagnostics ++
              allowed_tools_diagnostics(attrs, skill_file_path) ++
              metadata_diagnostics(attrs, skill_file_path) ++
              resource_diagnostics(resources, root_path)
        }

      {:ok, spec}
    else
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
    end
  end

  def parse_dir(_root_path) do
    {:error, [diagnostic(:error, :invalid_skill_root, "Skill root must be a path string.")]}
  end

  @doc """
  Parse many skill directories and return loadable specs plus aggregate diagnostics.

  Fatal parse errors are returned as diagnostics instead of exceptions. Duplicate
  names are reported as diagnostics but do not prevent parsing.
  """
  @spec parse_many([String.t()]) :: %{specs: [AgentSkillSpec.t()], diagnostics: [map()]}
  def parse_many(root_paths) when is_list(root_paths) do
    {specs, diagnostics} =
      root_paths
      |> Enum.map(&parse_dir/1)
      |> Enum.reduce({[], []}, fn
        {:ok, spec}, {specs, diagnostics} ->
          {[spec | specs], spec.diagnostics ++ diagnostics}

        {:error, parse_diagnostics}, {specs, diagnostics} ->
          {specs, parse_diagnostics ++ diagnostics}
      end)

    specs = Enum.reverse(specs)

    %{
      specs: specs,
      diagnostics: Enum.reverse(diagnostics) ++ duplicate_diagnostics(specs)
    }
  end

  defp read_skill_file(skill_file_path) do
    case File.read(skill_file_path) do
      {:ok, content} ->
        {:ok, content}

      {:error, :enoent} ->
        {:error,
         [
           diagnostic(:error, :missing_skill_md, "Missing required SKILL.md file.",
             path: skill_file_path
           )
         ]}

      {:error, reason} ->
        {:error,
         [
           diagnostic(:error, :skill_file_read_failed, "Could not read SKILL.md.",
             path: skill_file_path,
             value: reason
           )
         ]}
    end
  end

  defp split_frontmatter(content, skill_file_path) do
    case Regex.run(
           ~r/\A---[ \t]*\r?\n(?<frontmatter>.*?)(?:\r?\n)---[ \t]*(?:\r?\n|\z)(?<body>.*)\z/s,
           content,
           capture: ["frontmatter", "body"]
         ) do
      [frontmatter, body] ->
        {:ok, frontmatter, body}

      _match ->
        {:error,
         [
           diagnostic(
             :error,
             :missing_frontmatter,
             "SKILL.md must start with YAML frontmatter delimited by ---.",
             path: skill_file_path
           )
         ]}
    end
  end

  defp parse_frontmatter(frontmatter, skill_file_path) do
    case YamlElixir.read_from_string(frontmatter) do
      {:ok, nil} ->
        {:error,
         [
           diagnostic(:error, :empty_frontmatter, "SKILL.md frontmatter must be a map.",
             path: skill_file_path
           )
         ]}

      {:ok, attrs} when is_map(attrs) ->
        {:ok, attrs}

      {:ok, other} ->
        {:error,
         [
           diagnostic(:error, :frontmatter_not_map, "SKILL.md frontmatter must parse to a map.",
             path: skill_file_path,
             value: other
           )
         ]}

      {:error, reason} ->
        {:error,
         [
           diagnostic(:error, :invalid_yaml, "SKILL.md frontmatter could not be parsed.",
             path: skill_file_path,
             value: normalize_yaml_error(reason)
           )
         ]}
    end
  end

  defp validate_required_fields(attrs, skill_file_path) do
    @required_fields
    |> Enum.reject(&present_string?(Map.get(attrs, &1)))
    |> case do
      [] ->
        :ok

      missing ->
        {:error,
         Enum.map(missing, fn field ->
           diagnostic(:error, :missing_required_field, "Missing required #{field} field.",
             path: skill_file_path,
             field: field
           )
         end)}
    end
  end

  defp compatibility_diagnostics(attrs, root_path, skill_file_path) do
    []
    |> maybe_warn_invalid_name(attrs["name"], skill_file_path)
    |> maybe_warn_parent_mismatch(attrs["name"], root_path, skill_file_path)
    |> maybe_warn_oversized_field(attrs["description"], "description", skill_file_path)
    |> maybe_warn_oversized_field(attrs["compatibility"], "compatibility", skill_file_path)
    |> maybe_warn_external_fields(attrs, skill_file_path)
  end

  defp maybe_warn_invalid_name(diagnostics, name, skill_file_path) do
    if Regex.match?(@canonical_name_pattern, name) do
      diagnostics
    else
      [
        diagnostic(
          :warning,
          :invalid_name,
          "Skill name is not canonical Agent Skills kebab-case.",
          path: skill_file_path,
          field: "name",
          value: name
        )
        | diagnostics
      ]
    end
  end

  defp maybe_warn_parent_mismatch(diagnostics, name, root_path, skill_file_path) do
    if Path.basename(root_path) == name do
      diagnostics
    else
      [
        diagnostic(
          :warning,
          :parent_directory_mismatch,
          "Skill directory name does not match the frontmatter name.",
          path: skill_file_path,
          field: "name",
          value: %{directory: Path.basename(root_path), name: name}
        )
        | diagnostics
      ]
    end
  end

  defp maybe_warn_oversized_field(diagnostics, value, field, skill_file_path)
       when is_binary(value) do
    if String.length(value) > @description_limit do
      [
        diagnostic(
          :warning,
          :oversized_field,
          "#{field} is longer than #{@description_limit} characters.",
          path: skill_file_path,
          field: field,
          value: String.length(value)
        )
        | diagnostics
      ]
    else
      diagnostics
    end
  end

  defp maybe_warn_oversized_field(diagnostics, _value, _field, _skill_file_path), do: diagnostics

  defp maybe_warn_external_fields(diagnostics, attrs, skill_file_path) do
    attrs
    |> Map.drop(@known_fields)
    |> Map.keys()
    |> Enum.reduce(diagnostics, fn field, acc ->
      [
        diagnostic(
          :warning,
          :unknown_frontmatter_field,
          "Unknown frontmatter field is preserved.",
          path: skill_file_path,
          field: field
        )
        | acc
      ]
    end)
  end

  defp allowed_tools(attrs, _skill_file_path) do
    case Map.get(attrs, "allowed-tools") do
      nil -> []
      value when is_binary(value) -> [value]
      values when is_list(values) -> values
      value -> [value]
    end
  end

  defp allowed_tools_diagnostics(attrs, skill_file_path) do
    case Map.get(attrs, "allowed-tools") do
      nil ->
        []

      value when is_binary(value) ->
        []

      values when is_list(values) ->
        if Enum.all?(values, &is_binary/1) do
          []
        else
          [
            diagnostic(
              :warning,
              :invalid_allowed_tools,
              "allowed-tools should be a string or list of strings.",
              path: skill_file_path,
              field: "allowed-tools",
              value: values
            )
          ]
        end

      value ->
        [
          diagnostic(
            :warning,
            :invalid_allowed_tools,
            "allowed-tools should be a string or list of strings.",
            path: skill_file_path,
            field: "allowed-tools",
            value: value
          )
        ]
    end
  end

  defp metadata(attrs, _skill_file_path) do
    case Map.get(attrs, "metadata") do
      nil -> %{}
      value when is_map(value) -> value
      _value -> %{}
    end
  end

  defp metadata_diagnostics(attrs, skill_file_path) do
    case Map.get(attrs, "metadata") do
      nil ->
        []

      value when is_map(value) ->
        value
        |> Map.keys()
        |> Enum.filter(
          &(String.starts_with?(to_string(&1), "allbert.") and not known_allbert_key?(&1))
        )
        |> Enum.map(fn field ->
          diagnostic(
            :warning,
            :unknown_allbert_metadata,
            "Unknown Allbert metadata is preserved as inert context.",
            path: skill_file_path,
            field: to_string(field)
          )
        end)

      value ->
        [
          diagnostic(:warning, :invalid_metadata, "metadata must be a map when present.",
            path: skill_file_path,
            field: "metadata",
            value: value
          )
        ]
    end
  end

  defp known_allbert_key?(key), do: to_string(key) in @known_allbert_metadata

  defp inventory_resources(root_path) do
    @resource_dirs
    |> Enum.flat_map(fn {directory, kind} ->
      root_path
      |> Path.join(directory)
      |> inventory_resource_dir(root_path, kind)
    end)
    |> Enum.sort_by(& &1.path)
  end

  defp inventory_resource_dir(directory_path, root_path, kind) do
    if File.dir?(directory_path) do
      directory_path
      |> walk_resource_files()
      |> Enum.map(&resource_entry(&1, root_path, kind))
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  end

  defp walk_resource_files(directory_path) do
    directory_path
    |> File.ls()
    |> case do
      {:ok, entries} ->
        entries
        |> Enum.reject(&hidden_path_segment?/1)
        |> Enum.flat_map(&walk_resource_entry(directory_path, &1))

      {:error, _reason} ->
        []
    end
  end

  defp walk_resource_entry(directory_path, entry) do
    path = Path.join(directory_path, entry)

    cond do
      File.dir?(path) -> walk_resource_files(path)
      File.regular?(path) -> [path]
      true -> []
    end
  end

  defp resource_entry(path, root_path, kind) do
    with {:ok, stat} <- File.stat(path),
         {:ok, contents} <- File.read(path) do
      %Resource{
        path: Path.relative_to(path, root_path),
        kind: kind,
        byte_size: stat.size,
        sha256: contents |> sha256() |> Base.encode16(case: :lower)
      }
    else
      _error -> nil
    end
  end

  defp resource_diagnostics(resources, root_path) do
    resources
    |> Enum.filter(&(&1.kind == :script))
    |> Enum.map(fn resource ->
      diagnostic(
        :info,
        :script_resource_inert,
        "Bundled scripts are inventoried only and are not executed in v0.03.",
        path: Path.join(root_path, resource.path),
        value: resource.path
      )
    end)
  end

  defp duplicate_diagnostics(specs) do
    specs
    |> Enum.group_by(& &1.name)
    |> Enum.filter(fn {_name, specs} -> length(specs) > 1 end)
    |> Enum.flat_map(fn {name, duplicate_specs} ->
      Enum.map(duplicate_specs, fn spec ->
        diagnostic(:warning, :duplicate_skill_name, "Duplicate skill name discovered.",
          path: spec.skill_file_path,
          field: "name",
          value: name
        )
      end)
    end)
  end

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp hidden_path_segment?(segment), do: String.starts_with?(segment, ".")

  defp sha256(contents), do: :crypto.hash(:sha256, contents)

  defp normalize_yaml_error(%{message: message}), do: message
  defp normalize_yaml_error(reason), do: inspect(reason)

  defp diagnostic(severity, code, message, opts \\ []) do
    opts
    |> Enum.into(%{
      severity: severity,
      code: code,
      message: message
    })
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
