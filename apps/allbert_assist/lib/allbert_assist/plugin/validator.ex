defmodule AllbertAssist.Plugin.Validator do
  @moduledoc false

  alias AllbertAssist.Capabilities.ReleaseAvailability
  alias AllbertAssist.Plugin.Entry
  alias AllbertAssist.Plugin.Paths
  alias AllbertAssist.Settings.YamlCodec

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
  @approval_primitives [:button, :typed_command, :link, :list]
  @threading_capabilities [:native_threads, :reply_chain, :flat, :rich]
  @channel_trust_classes [:e2ee_origin, :server_readable, :local]
  @reply_key_types [:opaque_id, :timestamp]

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
      release_availability: [],
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
    release_availability = module_release_availability(module, opts)

    diagnostics =
      []
      |> validate_source(source)
      |> validate_status(status)
      |> validate_trust_status(trust_status)
      |> validate_plugin_id(module.plugin_id())
      |> validate_bounded_string(module.display_name(), :display_name, 64)
      |> validate_bounded_string(module.version(), :version, 32)
      |> validate_module_lists(module)
      |> validate_channel_descriptors(module.channels())
      |> validate_release_availability(release_availability, module)
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
         release_availability: normalized_release_availability(release_availability),
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

  defp validate_channel_descriptors(diagnostics, channels) when is_list(channels) do
    Enum.reduce(channels, diagnostics, fn descriptor, acc ->
      acc
      |> validate_channel_descriptor_map(descriptor)
      |> validate_channel_primitives(descriptor)
      |> validate_channel_threading(descriptor)
      |> validate_channel_trust_class(descriptor)
      |> validate_channel_reply_key_type(descriptor)
      |> validate_channel_quote_ttl_ms(descriptor)
    end)
  end

  defp validate_channel_descriptors(diagnostics, _channels) do
    [
      diagnostic(:error, :invalid_channels, "channels must be a list of descriptor maps.")
      | diagnostics
    ]
  end

  defp validate_channel_descriptor_map(diagnostics, descriptor) when is_map(descriptor),
    do: diagnostics

  defp validate_channel_descriptor_map(diagnostics, _descriptor) do
    [
      diagnostic(:error, :invalid_channel_descriptor, "Channel descriptor must be a map.")
      | diagnostics
    ]
  end

  defp validate_channel_primitives(diagnostics, descriptor) when is_map(descriptor) do
    primitives = Map.get(descriptor, :primitives, Map.get(descriptor, "primitives"))

    cond do
      not is_list(primitives) ->
        [
          diagnostic(
            :error,
            :missing_channel_primitives,
            "Channel descriptor missing primitives."
          )
          | diagnostics
        ]

      primitives == [] ->
        [
          diagnostic(:error, :empty_channel_primitives, "Channel primitives must not be empty.")
          | diagnostics
        ]

      not Enum.all?(primitives, &(&1 in @approval_primitives)) ->
        [
          diagnostic(
            :error,
            :invalid_channel_primitive,
            "Channel descriptor declares an unknown primitive.",
            allowed: @approval_primitives
          )
          | diagnostics
        ]

      :list not in primitives ->
        [
          diagnostic(
            :error,
            :missing_channel_list_primitive,
            "Channel primitives must include :list."
          )
          | diagnostics
        ]

      true ->
        diagnostics
    end
  end

  defp validate_channel_primitives(diagnostics, _descriptor), do: diagnostics

  defp validate_channel_threading(diagnostics, descriptor) when is_map(descriptor) do
    threading = Map.get(descriptor, :threading, Map.get(descriptor, "threading"))

    if threading in @threading_capabilities do
      diagnostics
    else
      [
        diagnostic(
          :error,
          :invalid_channel_threading,
          "Channel descriptor has invalid threading.",
          allowed: @threading_capabilities
        )
        | diagnostics
      ]
    end
  end

  defp validate_channel_threading(diagnostics, _descriptor), do: diagnostics

  defp validate_channel_trust_class(diagnostics, descriptor) when is_map(descriptor) do
    trust_class = Map.get(descriptor, :trust_class, Map.get(descriptor, "trust_class"))

    cond do
      trust_class in @channel_trust_classes ->
        diagnostics

      is_nil(trust_class) ->
        [
          diagnostic(
            :error,
            :missing_channel_trust_class,
            "Channel descriptor missing trust_class.",
            allowed: @channel_trust_classes
          )
          | diagnostics
        ]

      true ->
        [
          diagnostic(
            :error,
            :invalid_channel_trust_class,
            "Channel descriptor has invalid trust_class.",
            allowed: @channel_trust_classes
          )
          | diagnostics
        ]
    end
  end

  defp validate_channel_trust_class(diagnostics, _descriptor), do: diagnostics

  defp validate_channel_reply_key_type(diagnostics, descriptor) when is_map(descriptor) do
    reply_key_type = Map.get(descriptor, :reply_key_type, Map.get(descriptor, "reply_key_type"))

    cond do
      is_nil(reply_key_type) ->
        diagnostics

      reply_key_type in @reply_key_types ->
        diagnostics

      true ->
        [
          diagnostic(
            :error,
            :invalid_channel_reply_key_type,
            "Channel descriptor has invalid reply_key_type.",
            allowed: @reply_key_types
          )
          | diagnostics
        ]
    end
  end

  defp validate_channel_reply_key_type(diagnostics, _descriptor), do: diagnostics

  defp validate_channel_quote_ttl_ms(diagnostics, descriptor) when is_map(descriptor) do
    quote_ttl_ms = Map.get(descriptor, :quote_ttl_ms, Map.get(descriptor, "quote_ttl_ms"))

    cond do
      is_nil(quote_ttl_ms) ->
        diagnostics

      is_integer(quote_ttl_ms) and quote_ttl_ms > 0 ->
        diagnostics

      true ->
        [
          diagnostic(
            :error,
            :invalid_channel_quote_ttl_ms,
            "Channel descriptor has invalid quote_ttl_ms.",
            allowed: "positive_integer"
          )
          | diagnostics
        ]
    end
  end

  defp validate_channel_quote_ttl_ms(diagnostics, _descriptor), do: diagnostics

  defp validate_release_availability(diagnostics, {:ok, declarations}, module) do
    case release_availability_ownership_errors(declarations, module) do
      [] ->
        diagnostics

      errors ->
        [
          diagnostic(
            :error,
            :release_availability_not_owned,
            "Plugin release availability declarations must describe capabilities contributed by the same plugin.",
            errors: errors
          )
          | diagnostics
        ]
    end
  end

  defp validate_release_availability(diagnostics, {:error, errors}, _module) do
    [
      diagnostic(
        :error,
        :invalid_release_availability,
        "Plugin release availability declarations are invalid.",
        errors: errors
      )
      | diagnostics
    ]
  end

  defp normalized_release_availability({:ok, declarations}), do: declarations
  defp normalized_release_availability({:error, _errors}), do: []

  defp module_release_availability(module, opts) do
    with {:ok, yaml_declarations} <- yaml_release_availability(module, opts) do
      module
      |> callback_release_availability()
      |> append_release_declarations(yaml_declarations)
      |> ReleaseAvailability.normalize_declarations()
    end
  end

  defp callback_release_availability(module) do
    if function_exported?(module, :release_availability, 0),
      do: module.release_availability(),
      else: []
  end

  defp append_release_declarations(declarations, yaml_declarations) when is_list(declarations),
    do: declarations ++ yaml_declarations

  defp append_release_declarations(declarations, _yaml_declarations), do: declarations

  defp yaml_release_availability(module, opts) do
    case release_availability_yaml_path(module, opts) do
      nil ->
        {:ok, []}

      path ->
        path
        |> YamlCodec.read_file()
        |> yaml_release_declarations(path)
    end
  end

  defp release_availability_yaml_path(module, opts) do
    root_path = Map.get(opts, :root_path) || inferred_plugin_root(module)

    if is_binary(root_path) do
      Path.join([root_path, "priv", "allbert", "release_availability.yaml"])
    end
  end

  # v0.62 M1: resolve through the release-safe plugins root, not cwd.
  defp inferred_plugin_root(module) do
    with true <- function_exported?(module, :plugin_id, 0),
         plugin_id when is_binary(plugin_id) <- module.plugin_id(),
         root_path when is_binary(root_path) <-
           Paths.plugin_root(plugin_id),
         true <- File.dir?(root_path) do
      root_path
    else
      _other -> nil
    end
  end

  defp yaml_release_declarations({:ok, map}, path) when is_map(map) do
    case Map.get(map, "declarations", Map.get(map, :declarations, [])) do
      declarations when is_list(declarations) ->
        {:ok, declarations}

      _other ->
        {:error, [{:invalid_release_availability_yaml, path, :expected_declarations_list}]}
    end
  end

  defp yaml_release_declarations({:error, reason}, path) do
    {:error, [{:release_availability_yaml_parse_failed, path, reason}]}
  end

  defp release_availability_ownership_errors(declarations, module) do
    declarations
    |> Enum.reject(&owned_release_declaration?(&1, module))
    |> Enum.map(fn declaration ->
      %{kind: declaration.kind, id: declaration.id, plugin_id: module.plugin_id()}
    end)
  end

  defp owned_release_declaration?(%{kind: :channel, id: id}, module),
    do: id in channel_ids(module)

  defp owned_release_declaration?(%{kind: :plugin, id: id}, module),
    do: id == module.plugin_id()

  defp owned_release_declaration?(%{kind: :action, id: id}, module),
    do: id in action_names(module)

  defp owned_release_declaration?(%{kind: :app, id: id}, module),
    do: id in app_ids(module)

  defp owned_release_declaration?(_declaration, _module), do: false

  defp channel_ids(module) do
    module.channels()
    |> List.wrap()
    |> Enum.flat_map(&channel_id/1)
  end

  defp channel_id(%{} = descriptor) do
    case Map.get(descriptor, :channel_id, Map.get(descriptor, "channel_id")) do
      id when is_binary(id) -> [id]
      _other -> []
    end
  end

  defp channel_id(_descriptor), do: []

  defp action_names(module) do
    module.actions()
    |> List.wrap()
    |> Enum.flat_map(&action_name/1)
  end

  defp action_name(action_module) when is_atom(action_module) do
    with true <- Code.ensure_loaded?(action_module),
         true <- function_exported?(action_module, :name, 0),
         name when is_binary(name) <- action_module.name() do
      [name]
    else
      _other -> []
    end
  rescue
    _exception -> []
  end

  defp action_name(_action_module), do: []

  defp app_ids(module) do
    module.apps()
    |> List.wrap()
    |> Enum.flat_map(&app_id/1)
  end

  defp app_id(app_module) when is_atom(app_module) do
    with true <- Code.ensure_loaded?(app_module),
         true <- function_exported?(app_module, :app_id, 0) do
      case app_module.app_id() do
        id when is_atom(id) -> [Atom.to_string(id)]
        id when is_binary(id) -> [id]
        _other -> []
      end
    else
      _other -> []
    end
  rescue
    _exception -> []
  end

  defp app_id(_app_module), do: []

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
