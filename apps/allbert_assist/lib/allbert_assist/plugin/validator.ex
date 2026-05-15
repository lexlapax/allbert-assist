defmodule AllbertAssist.Plugin.Validator do
  @moduledoc false

  alias AllbertAssist.Plugin.Entry

  @plugin_id_regex ~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$/
  @required_callbacks [
    plugin_id: 0,
    display_name: 0,
    version: 0,
    validate: 1
  ]
  @sources [:shipped, :project, :home]
  @statuses [:enabled, :disabled, :invalid, :rejected]
  @trust_statuses [:trusted, :pending, :untrusted]

  @spec validate_module(module(), keyword() | map()) ::
          {:ok, Entry.t()} | {:error, term(), [map()]}
  def validate_module(module, opts \\ []) when is_atom(module) do
    opts = opts_map(opts)

    with :ok <- ensure_loaded(module),
         :ok <- ensure_callbacks(module),
         :ok <- run_plugin_validate(module, opts),
         {:ok, attrs} <- module_attrs(module, opts) do
      {:ok, struct!(Entry, attrs)}
    else
      {:error, reason, diagnostics} ->
        {:error, reason, diagnostics}

      {:error, reason} ->
        {:error, reason, [diagnostic(:error, :module_not_loaded, "Invalid plugin module.")]}
    end
  rescue
    exception ->
      reason = {:plugin_exception, Exception.message(exception)}
      {:error, reason, [diagnostic(:error, :plugin_exception, Exception.message(exception))]}
  end

  @spec normalize_manifest(map(), keyword() | map()) ::
          {:ok, Entry.t()} | {:error, term(), [map()]}
  def normalize_manifest(manifest, opts \\ [])

  def normalize_manifest(manifest, opts) when is_map(manifest) do
    opts = opts_map(opts)
    source = Map.get(opts, :source, :home)
    root_path = Map.get(opts, :root_path)
    manifest_path = Map.get(opts, :manifest_path)

    diagnostics =
      []
      |> validate_source(source)
      |> validate_manifest_schema(manifest)
      |> validate_manifest_strings(manifest)
      |> validate_manifest_skill_paths(manifest, root_path)
      |> validate_code_bearing_manifest(manifest, source)

    status = manifest_status(diagnostics)

    attrs = %{
      plugin_id: string_field(manifest, "plugin_id", ""),
      display_name: string_field(manifest, "name", ""),
      version: string_field(manifest, "version", ""),
      kind: string_field(manifest, "kind", "skills"),
      source: source,
      status: status,
      trust_status: trust_status_for(source, opts),
      module: nil,
      root_path: root_path,
      manifest_path: manifest_path,
      apps: [],
      channels: [],
      actions: [],
      skill_paths: manifest_skill_paths(manifest, root_path),
      settings_schema: [],
      children: :ignore,
      diagnostics: diagnostics
    }

    entry = struct!(Entry, attrs)

    if status in [:invalid, :rejected] do
      {:error, status, diagnostics}
    else
      {:ok, entry}
    end
  end

  def normalize_manifest(_manifest, _opts) do
    {:error, :invalid_manifest,
     [diagnostic(:error, :invalid_manifest, "Manifest must be a map.")]}
  end

  @spec valid_plugin_id?(term()) :: boolean()
  def valid_plugin_id?(plugin_id) when is_binary(plugin_id) do
    String.length(plugin_id) <= 96 and Regex.match?(@plugin_id_regex, plugin_id)
  end

  def valid_plugin_id?(_plugin_id), do: false

  @spec diagnostic(atom(), atom(), String.t(), keyword()) :: map()
  def diagnostic(severity, kind, message, detail \\ []) do
    %{severity: severity, kind: kind, message: message, detail: Map.new(detail)}
  end

  defp ensure_loaded(module) do
    if Code.ensure_loaded?(module), do: :ok, else: {:error, {:module_not_loaded, module}}
  end

  defp ensure_callbacks(module) do
    missing =
      Enum.reject(@required_callbacks, fn {name, arity} ->
        function_exported?(module, name, arity)
      end)

    case missing do
      [] ->
        :ok

      callbacks ->
        {:error, {:missing_callbacks, callbacks},
         [
           diagnostic(:error, :missing_callbacks, "Plugin is missing required callbacks.",
             callbacks: callbacks
           )
         ]}
    end
  end

  defp run_plugin_validate(module, opts) do
    case module.validate(opts) do
      :ok ->
        :ok

      {:error, diagnostics} when is_list(diagnostics) ->
        {:error, :plugin_validation_failed, diagnostics}

      other ->
        {:error, {:invalid_validate_result, other},
         [diagnostic(:error, :invalid_validate_result, "validate/1 returned an invalid value.")]}
    end
  end

  defp module_attrs(module, opts) do
    source = Map.get(opts, :source, :shipped)
    status = Map.get(opts, :status, :enabled)
    trust_status = trust_status_for(source, opts)

    diagnostics =
      []
      |> validate_source(source)
      |> validate_status(status)
      |> validate_trust_status(trust_status)
      |> validate_plugin_id(module.plugin_id())
      |> validate_bounded_string(module.display_name(), :display_name, 64)
      |> validate_bounded_string(module.version(), :version, 32)
      |> validate_module_lists(module)
      |> duplicate_contribution_diagnostics(module)

    if Enum.any?(diagnostics, &(&1.severity == :error)) do
      {:error, :invalid_plugin, diagnostics}
    else
      {:ok,
       %{
         plugin_id: module.plugin_id(),
         display_name: String.trim(module.display_name()),
         version: String.trim(module.version()),
         kind: Map.get(opts, :kind, infer_kind(module)),
         source: source,
         status: status,
         trust_status: trust_status,
         module: module,
         root_path: Map.get(opts, :root_path),
         manifest_path: Map.get(opts, :manifest_path),
         apps: module.apps(),
         channels: module.channels(),
         actions: module.actions(),
         skill_paths: module.skill_paths(),
         settings_schema: module.settings_schema(),
         children: module.child_spec([]),
         diagnostics: diagnostics
       }}
    end
  end

  defp validate_source(diagnostics, source) when source in @sources, do: diagnostics

  defp validate_source(diagnostics, source) do
    [
      diagnostic(:error, :invalid_source, "Plugin source is invalid.", source: source)
      | diagnostics
    ]
  end

  defp validate_status(diagnostics, status) when status in @statuses, do: diagnostics

  defp validate_status(diagnostics, status) do
    [
      diagnostic(:error, :invalid_status, "Plugin status is invalid.", status: status)
      | diagnostics
    ]
  end

  defp validate_trust_status(diagnostics, trust_status) when trust_status in @trust_statuses,
    do: diagnostics

  defp validate_trust_status(diagnostics, trust_status) do
    [
      diagnostic(:error, :invalid_trust_status, "Plugin trust status is invalid.",
        trust_status: trust_status
      )
      | diagnostics
    ]
  end

  defp validate_plugin_id(diagnostics, plugin_id) do
    if valid_plugin_id?(plugin_id) do
      diagnostics
    else
      [
        diagnostic(:error, :invalid_plugin_id, "Plugin id must be a lowercase dotted string.")
        | diagnostics
      ]
    end
  end

  defp validate_bounded_string(diagnostics, value, field, max) do
    valid? = is_binary(value) and String.trim(value) != "" and String.length(value) <= max

    if valid? do
      diagnostics
    else
      [
        diagnostic(:error, :"invalid_#{field}", "#{field} must be a bounded non-empty string.")
        | diagnostics
      ]
    end
  end

  defp validate_module_lists(diagnostics, module) do
    [
      {:apps, module.apps()},
      {:actions, module.actions()}
    ]
    |> Enum.reduce(diagnostics, fn {field, modules}, acc ->
      if is_list(modules) and Enum.all?(modules, &is_atom/1) do
        acc
      else
        [diagnostic(:error, :"invalid_#{field}", "#{field} must be a list of modules.") | acc]
      end
    end)
  end

  defp duplicate_contribution_diagnostics(diagnostics, module) do
    diagnostics ++
      duplicate_diagnostics(module.apps(), :duplicate_app_module) ++
      duplicate_diagnostics(module.actions(), :duplicate_action_module) ++
      duplicate_channel_diagnostics(module.channels()) ++
      duplicate_diagnostics(module.skill_paths(), :duplicate_skill_path)
  end

  defp duplicate_diagnostics(values, kind) when is_list(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} ->
      diagnostic(:warning, kind, "Duplicate plugin contribution.", value: value)
    end)
  end

  defp duplicate_diagnostics(_values, _kind), do: []

  defp duplicate_channel_diagnostics(channels) when is_list(channels) do
    channels
    |> Enum.map(&Map.get(&1, :channel_id, Map.get(&1, "channel_id")))
    |> duplicate_diagnostics(:duplicate_channel_id)
  end

  defp duplicate_channel_diagnostics(_channels), do: []

  defp infer_kind(module) do
    cond do
      module.channels() != [] -> "channel"
      module.apps() != [] -> "app"
      module.actions() != [] -> "actions"
      module.skill_paths() != [] -> "skills"
      true -> "mixed"
    end
  end

  defp trust_status_for(source, opts) do
    Map.get(opts, :trust_status) ||
      case source do
        :shipped -> :trusted
        :project -> :pending
        :home -> :pending
        _other -> :untrusted
      end
  end

  defp validate_manifest_schema(diagnostics, %{"schema_version" => 1}), do: diagnostics

  defp validate_manifest_schema(diagnostics, _manifest) do
    [
      diagnostic(:error, :invalid_schema_version, "Plugin manifest schema_version must be 1.")
      | diagnostics
    ]
  end

  defp validate_manifest_strings(diagnostics, manifest) do
    diagnostics
    |> validate_plugin_id(Map.get(manifest, "plugin_id"))
    |> validate_bounded_string(Map.get(manifest, "name"), :name, 64)
    |> validate_bounded_string(Map.get(manifest, "version"), :version, 32)
    |> validate_bounded_string(Map.get(manifest, "kind", "skills"), :kind, 32)
  end

  defp validate_manifest_skill_paths(diagnostics, manifest, root_path) do
    skill_paths = Map.get(manifest, "skill_paths", [])

    cond do
      not is_list(skill_paths) ->
        [diagnostic(:error, :invalid_skill_paths, "skill_paths must be a list.") | diagnostics]

      root_path == nil ->
        diagnostics

      true ->
        validate_manifest_skill_path_entries(skill_paths, diagnostics, root_path)
    end
  end

  defp validate_manifest_skill_path_entries(skill_paths, diagnostics, root_path) do
    Enum.reduce(skill_paths, diagnostics, fn path, acc ->
      validate_manifest_skill_path_entry(path, acc, root_path)
    end)
  end

  defp validate_manifest_skill_path_entry(path, diagnostics, root_path) do
    if valid_relative_path?(path, root_path) do
      diagnostics
    else
      [
        diagnostic(:error, :invalid_skill_path, "Skill path must stay inside plugin root.")
        | diagnostics
      ]
    end
  end

  defp validate_code_bearing_manifest(diagnostics, manifest, :home) do
    code_contributions? =
      Map.has_key?(manifest, "module") or
        manifest_contribution_nonempty?(manifest, "apps") or
        manifest_contribution_nonempty?(manifest, "actions") or
        manifest_contribution_nonempty?(manifest, "channels") or
        manifest_contribution_nonempty?(manifest, "children")

    if code_contributions? do
      [
        diagnostic(
          :error,
          :code_bearing_home_plugin,
          "Home plugins cannot contribute code-bearing modules in v0.17."
        )
        | diagnostics
      ]
    else
      diagnostics
    end
  end

  defp validate_code_bearing_manifest(diagnostics, _manifest, _source), do: diagnostics

  defp manifest_contribution_nonempty?(manifest, key) do
    manifest
    |> Map.get("contributions", %{})
    |> Map.get(key, [])
    |> case do
      value when is_list(value) -> value != []
      nil -> false
      _value -> true
    end
  end

  defp manifest_status(diagnostics) do
    cond do
      Enum.any?(diagnostics, &(&1.kind == :code_bearing_home_plugin)) -> :rejected
      Enum.any?(diagnostics, &(&1.severity == :error)) -> :invalid
      true -> :enabled
    end
  end

  defp manifest_skill_paths(manifest, root_path) do
    manifest
    |> Map.get("skill_paths", [])
    |> case do
      paths when is_list(paths) and is_binary(root_path) ->
        paths
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&Path.expand(&1, root_path))
        |> Enum.filter(&inside_path?(&1, root_path))

      _other ->
        []
    end
  end

  defp string_field(map, key, default) do
    case Map.get(map, key, default) do
      value when is_binary(value) -> String.trim(value)
      _value -> default
    end
  end

  defp valid_relative_path?(path, root_path) when is_binary(path) do
    Path.type(path) != :absolute and inside_path?(Path.expand(path, root_path), root_path)
  end

  defp valid_relative_path?(_path, _root_path), do: false

  defp inside_path?(path, root_path) do
    root = Path.expand(root_path)
    expanded = Path.expand(path)
    expanded == root or String.starts_with?(expanded, root <> "/")
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(_opts), do: %{}
end
