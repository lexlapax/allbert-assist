defmodule AllbertAssist.Pack.LegacyAdapter do
  @moduledoc """
  Captures the frozen legacy registries as one inert Pack candidate.

  The adapter is a read-only migration seam. It does not reconcile Pack
  projection input, mutate a legacy registry, start children, emit signals, or
  consult compatibility fixtures.
  """

  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Intent.Descriptor, as: IntentDescriptor
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Pack.ActionBinding
  alias AllbertAssist.Pack.Canonical
  alias AllbertAssist.Pack.Compatibility
  alias AllbertAssist.Pack.CompatibilityAlias
  alias AllbertAssist.Pack.CompatibilityDiagnostic
  alias AllbertAssist.Pack.Contribution
  alias AllbertAssist.Pack.Order
  alias AllbertAssist.Pack.Owner
  alias AllbertAssist.Pack.OwnerRef
  alias AllbertAssist.Pack.PathSegment
  alias AllbertAssist.Pack.Projection
  alias AllbertAssist.Pack.Projection.Closed
  alias AllbertAssist.Pack.Registry.Candidate
  alias AllbertAssist.Pack.Row
  alias AllbertAssist.Pack.RowSchemas
  alias AllbertAssist.Pack.Target
  alias AllbertAssist.Pack.ValidationDiagnostic
  alias AllbertAssist.Plugin.Discovery, as: PluginDiscovery
  alias AllbertAssist.Plugin.Entry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugin.Validator, as: PluginValidator
  alias AllbertAssist.RegistryContext
  alias AllbertAssist.Settings.Fragments, as: SettingsFragments

  @option_keys [:pack_projection, :app, :plugin, :actions_overlay]
  @app_entry_keys MapSet.new([
                    :actions,
                    :agents,
                    :app_id,
                    :child_id,
                    :child_pid,
                    :display_name,
                    :memory_namespace,
                    :metadata,
                    :module,
                    :provider_surfaces,
                    :registered_at_ms,
                    :settings_schema,
                    :signals,
                    :skill_paths,
                    :surface_catalog,
                    :surface_provider,
                    :surfaces,
                    :version
                  ])
  @plugin_entry_keys PluginEntry.__struct__() |> Map.keys() |> MapSet.new()
  @app_module_callbacks [
    app_id: 0,
    display_name: 0,
    version: 0,
    validate: 1,
    child_spec: 1,
    agents: 0,
    actions: 0,
    signals: 0,
    skill_paths: 0,
    settings_schema: 0,
    surfaces: 0
  ]
  @plugin_module_callbacks [
    plugin_id: 0,
    display_name: 0,
    version: 0,
    validate: 1,
    apps: 0,
    channels: 0,
    actions: 0,
    skill_paths: 0,
    settings_schema: 0,
    release_availability: 0,
    child_spec: 1
  ]
  @callback_names [
    :apps,
    :actions,
    :settings_fragments,
    :settings_migrations,
    :channels,
    :surfaces,
    :skill_roots,
    :home_roots,
    :jobs,
    :stores,
    :prompt_rules,
    :intent_descriptors,
    :cli_groups,
    :release_assets,
    :test_lanes
  ]
  @excluded_overlay :allbert_pack_legacy_adapter_excluded_overlay
  @residual_owner_id "allbert_assist"
  @alias_digest_domain "allbert.pack.alias.authority.v1\0"
  @child_args_digest_domain "allbert.pack.child_spec.args.v1\0"

  @spec capture(keyword()) ::
          {:ok, Candidate.t()}
          | {:error, {:capture_failed, [ValidationDiagnostic.t()]}}
  def capture(opts) do
    with :ok <- validate_keyword(opts),
         :ok <- reject_duplicate_options(opts),
         :ok <- reject_unknown_options(opts),
         :ok <- require_pack_projection(opts),
         :ok <- validate_option_types(opts) do
      capture_valid(opts)
    end
  rescue
    _exception -> capture_error(:invalid_value, [], %{reason: :unstable_registry_capture})
  catch
    :exit, _reason -> capture_error(:invalid_value, [], %{reason: :unstable_registry_capture})
    _kind, _reason -> capture_error(:invalid_value, [], %{reason: :unstable_registry_capture})
  end

  defp validate_keyword(opts) do
    if Keyword.keyword?(opts) do
      :ok
    else
      capture_error(:invalid_type, [], %{
        expected: "keyword_list",
        actual: value_kind(opts)
      })
    end
  end

  defp reject_duplicate_options(opts) do
    duplicate_keys =
      opts
      |> Keyword.keys()
      |> Enum.frequencies()
      |> Enum.filter(fn {_key, count} -> count > 1 end)
      |> Enum.map(fn {key, _count} -> key end)
      |> Enum.sort()

    case duplicate_keys do
      [] ->
        :ok

      keys ->
        diagnostics =
          Enum.map(keys, fn key ->
            diagnostic(:invalid_value, [field_segment(Atom.to_string(key))], %{
              reason: :duplicate_option
            })
          end)

        {:error, {:capture_failed, diagnostics}}
    end
  end

  defp reject_unknown_options(opts) do
    unknown_keys =
      opts
      |> Keyword.keys()
      |> Enum.reject(&(&1 in @option_keys))
      |> Enum.uniq()
      |> Enum.sort()

    case unknown_keys do
      [] ->
        :ok

      keys ->
        diagnostics =
          Enum.map(keys, fn key ->
            field = Atom.to_string(key)
            diagnostic(:unknown_field, [field_segment(field)], %{field: field})
          end)

        {:error, {:capture_failed, diagnostics}}
    end
  end

  defp require_pack_projection(opts) do
    if Keyword.has_key?(opts, :pack_projection) do
      :ok
    else
      capture_error(:missing_field, [field_segment("pack_projection")], %{
        field: "pack_projection"
      })
    end
  end

  defp validate_option_types(opts) do
    with :ok <- validate_projection_type(Keyword.fetch!(opts, :pack_projection)),
         :ok <- validate_registry_selector(opts, :app),
         :ok <- validate_registry_selector(opts, :plugin) do
      validate_overlay_selector(opts)
    end
  end

  defp validate_projection_type(%Closed{}), do: :ok

  defp validate_projection_type(value) do
    capture_error(:invalid_type, [field_segment("pack_projection")], %{
      expected: "closed_pack_projection",
      actual: value_kind(value)
    })
  end

  defp validate_registry_selector(opts, key) do
    case Keyword.fetch(opts, key) do
      :error ->
        :ok

      {:ok, value} ->
        cond do
          not Keyword.keyword?(value) ->
            capture_error(:invalid_type, [field_segment(Atom.to_string(key))], %{
              expected: "keyword_list",
              actual: value_kind(value)
            })

          valid_registry_context?(value) ->
            :ok

          true ->
            capture_error(:invalid_type, [field_segment(Atom.to_string(key))], %{
              expected: "registry_context",
              actual: "keyword_list"
            })
        end
    end
  end

  defp validate_overlay_selector(opts) do
    case Keyword.fetch(opts, :actions_overlay) do
      :error ->
        :ok

      {:ok, value} ->
        if gen_server?(value) do
          :ok
        else
          capture_error(:invalid_type, [field_segment("actions_overlay")], %{
            expected: "gen_server",
            actual: value_kind(value)
          })
        end
    end
  end

  defp valid_registry_context?(value) do
    keys = Keyword.keys(value)

    keys -- [:server] == [] and
      Enum.all?(Enum.frequencies(keys), fn {_key, count} -> count == 1 end) and
      valid_registry_server?(value)
  end

  defp valid_registry_server?(value) do
    case Keyword.fetch(value, :server) do
      :error -> true
      {:ok, server} -> gen_server?(server)
    end
  end

  defp gen_server?(server) when is_pid(server), do: true

  defp gen_server?(server) when is_atom(server),
    do: server not in [nil, true, false]

  defp gen_server?({:global, _name}), do: true

  defp gen_server?({:via, module, _name}) when is_atom(module) do
    module not in [nil, true, false] and Code.ensure_loaded?(module) and
      function_exported?(module, :whereis_name, 1)
  end

  defp gen_server?({name, node}) when is_atom(name) and is_atom(node),
    do: name not in [nil, true, false] and node not in [nil, true, false]

  defp gen_server?(_server), do: false

  defp capture_valid(opts) do
    case opts |> Keyword.fetch!(:pack_projection) |> Projection.validate_closed() do
      :ok ->
        capture_registries(opts)

      {:error, {:invalid_projection, _reason}} ->
        capture_error(:invalid_value, [field_segment("pack_projection")], %{
          reason: :unreconciled_pack_projection
        })
    end
  end

  defp capture_registries(opts) do
    with {:ok, state} <- stable_registry_state(opts),
         {:ok, candidate} <- build_candidate(Keyword.fetch!(opts, :pack_projection), state),
         :ok <- canonical_candidate?(candidate) do
      {:ok, candidate}
    else
      {:error, :registry_unavailable} ->
        capture_error(:invalid_value, [], %{reason: :registry_unavailable})

      {:error, :unstable_registry_capture} ->
        capture_error(:invalid_value, [], %{reason: :unstable_registry_capture})
    end
  end

  defp stable_registry_state(opts) do
    app_opts = opts |> Keyword.get(:app, []) |> Keyword.put_new(:server, AppRegistry)
    plugin_opts = opts |> Keyword.get(:plugin, []) |> Keyword.put_new(:server, PluginRegistry)

    context = [
      app: app_opts,
      plugin: plugin_opts,
      actions_overlay: @excluded_overlay
    ]

    with :ok <- require_excluded_overlay_absent(),
         {:ok, app_pid} <- registry_pid(Keyword.get(app_opts, :server, AppRegistry)),
         {:ok, plugin_pid} <- registry_pid(Keyword.get(plugin_opts, :server, PluginRegistry)) do
      monitored_registry_state(app_pid, plugin_pid, context)
    else
      {:error, :unstable_registry_capture} = error -> error
      {:error, :registry_unavailable} = error -> error
    end
  end

  defp monitored_registry_state(app_pid, plugin_pid, context) do
    monitors = [Process.monitor(app_pid), Process.monitor(plugin_pid)]

    try do
      with {:ok, first} <- read_registry_state(context),
           :ok <- require_excluded_overlay_absent(),
           {:ok, second} <- read_registry_state(context),
           :ok <- require_excluded_overlay_absent() do
        cond do
          registry_down?(monitors) ->
            {:error, :registry_unavailable}

          not Process.alive?(app_pid) or not Process.alive?(plugin_pid) ->
            {:error, :registry_unavailable}

          registry_pid(Keyword.fetch!(context, :app)[:server]) != {:ok, app_pid} ->
            {:error, :unstable_registry_capture}

          registry_pid(Keyword.fetch!(context, :plugin)[:server]) != {:ok, plugin_pid} ->
            {:error, :unstable_registry_capture}

          first != second ->
            {:error, :unstable_registry_capture}

          true ->
            {:ok, first}
        end
      end
    after
      Enum.each(monitors, &Process.demonitor(&1, [:flush]))
    end
  end

  defp read_registry_state(context) do
    app_opts = Keyword.fetch!(context, :app)
    plugin_opts = Keyword.fetch!(context, :plugin)

    with {:ok, apps} <- AppRegistry.ordered_entries(app_opts),
         {:ok, plugins} <- PluginRegistry.ordered_entries(plugin_opts),
         :ok <- validate_observed_entries(apps, plugins),
         :ok <- require_excluded_overlay_absent(),
         action_modules = ActionsRegistry.modules(context),
         :ok <- require_excluded_overlay_absent(),
         :ok <- require_excluded_overlay_absent(),
         action_capabilities = ActionsRegistry.capabilities(context),
         :ok <- require_excluded_overlay_absent(),
         {:ok, intent_descriptors} <-
           strict_intent_descriptors(apps, plugins, context, action_capabilities) do
      {:ok,
       %{
         apps: apps,
         plugins: plugins,
         action_modules: action_modules,
         action_capabilities: action_capabilities,
         extensions: exact_extension_observation(apps, plugins, intent_descriptors),
         settings_fragments: SettingsFragments.registered_fragments(context)
       }}
    else
      {:error, :unavailable} -> {:error, :registry_unavailable}
      {:error, :unstable_registry_capture} -> {:error, :unstable_registry_capture}
    end
  end

  defp require_excluded_overlay_absent do
    if is_nil(Process.whereis(@excluded_overlay)) do
      :ok
    else
      {:error, :unstable_registry_capture}
    end
  end

  defp canonical_candidate?(%Candidate{} = candidate) do
    case Canonical.build_snapshot(candidate, :shadow) do
      {:ok, _unused_snapshot} -> :ok
      {:error, _diagnostics} -> {:error, :unstable_registry_capture}
    end
  rescue
    _exception -> {:error, :unstable_registry_capture}
  catch
    _kind, _reason -> {:error, :unstable_registry_capture}
  end

  defp validate_observed_entries(apps, plugins) when is_list(apps) and is_list(plugins) do
    with :ok <- validate_observed_apps(apps),
         :ok <- validate_observed_plugins(plugins) do
      :ok
    end
  end

  defp validate_observed_entries(_apps, _plugins), do: {:error, :unstable_registry_capture}

  defp validate_observed_apps(apps) do
    if Enum.all?(apps, &valid_observed_app?/1) do
      :ok
    else
      {:error, :unstable_registry_capture}
    end
  end

  defp valid_observed_app?(%{signals: %{emits: _emits, subscribes: _subscribes}} = entry) do
    MapSet.equal?(MapSet.new(Map.keys(entry)), @app_entry_keys) and
      valid_observed_app_identity?(entry) and
      valid_observed_app_registrations?(entry) and
      valid_observed_app_surfaces?(entry) and
      valid_observed_app_runtime?(entry)
  end

  defp valid_observed_app?(_entry), do: false

  defp valid_observed_app_identity?(entry) do
    valid_app_id?(entry.app_id) and
      valid_behaviour_module?(entry.module, AllbertAssist.App, @app_module_callbacks) and
      canonical_string?(entry.display_name) and
      canonical_string?(entry.version)
  end

  defp valid_observed_app_registrations?(entry) do
    module_list?(entry.agents) and module_list?(entry.actions) and
      string_list?(entry.signals.emits) and string_list?(entry.signals.subscribes) and
      string_list?(entry.skill_paths) and map_list?(entry.settings_schema) and
      valid_memory_namespace?(entry.memory_namespace, entry.app_id)
  end

  defp valid_observed_app_surfaces?(entry) do
    map_list?(entry.surfaces) and valid_optional_module?(entry.surface_provider) and
      map_list?(entry.provider_surfaces) and map_list?(entry.surface_catalog)
  end

  defp valid_observed_app_runtime?(entry) do
    valid_app_child_id?(entry.child_id) and valid_app_child_pid?(entry.child_pid) and
      is_integer(entry.registered_at_ms) and entry.registered_at_ms >= 0 and
      is_map(entry.metadata)
  end

  defp validate_observed_plugins(plugins) do
    if Enum.all?(plugins, &valid_observed_plugin?/1) do
      :ok
    else
      {:error, :unstable_registry_capture}
    end
  end

  defp valid_observed_plugin?(%PluginEntry{} = plugin) do
    MapSet.equal?(MapSet.new(Map.keys(plugin)), @plugin_entry_keys) and
      valid_observed_plugin_identity?(plugin) and
      valid_observed_plugin_contributions?(plugin) and
      valid_observed_plugin_metadata?(plugin)
  end

  defp valid_observed_plugin?(_entry), do: false

  defp valid_observed_plugin_identity?(plugin) do
    PluginValidator.valid_plugin_id?(plugin.plugin_id) and
      canonical_string?(plugin.display_name) and canonical_string?(plugin.version) and
      canonical_string?(plugin.kind) and plugin.source in [:shipped, :project, :home] and
      plugin.status in [:enabled, :disabled] and
      plugin.trust_status in [:trusted, :pending, :untrusted]
  end

  defp valid_observed_plugin_contributions?(plugin) do
    valid_plugin_module_carrier?(plugin) and module_list?(plugin.apps) and
      module_list?(plugin.actions) and map_list?(plugin.channels) and
      string_list?(plugin.skill_paths) and map_list?(plugin.settings_schema)
  end

  defp valid_observed_plugin_metadata?(plugin) do
    map_list?(plugin.release_availability) and valid_plugin_children?(plugin.children) and
      map_list?(plugin.diagnostics) and optional_string?(plugin.root_path) and
      optional_string?(plugin.manifest_path)
  end

  defp valid_plugin_module_carrier?(%PluginEntry{module: module} = plugin)
       when is_atom(module) and module not in [nil, true, false] do
    valid_behaviour_module?(module, AllbertAssist.Plugin, @plugin_module_callbacks) and
      plugin_module_matches_source?(plugin)
  end

  defp valid_plugin_module_carrier?(%PluginEntry{module: nil} = plugin) do
    plugin.source in [:project, :home] and canonical_string?(plugin.root_path) and
      plugin.apps == [] and plugin.actions == [] and plugin.channels == [] and
      plugin.settings_schema == [] and plugin.release_availability == [] and
      plugin.children == :ignore
  end

  defp valid_plugin_module_carrier?(_plugin), do: false

  defp valid_behaviour_module?(module, behaviour, callbacks) do
    proper_module?(module) and Code.ensure_loaded?(module) and
      module_declares_behaviour?(module, behaviour) and
      Enum.all?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end)
  end

  defp module_declares_behaviour?(module, behaviour) do
    module
    |> apply(:module_info, [:attributes])
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
    |> Enum.member?(behaviour)
  end

  defp plugin_module_matches_source?(%PluginEntry{
         source: :shipped,
         plugin_id: plugin_id,
         module: module
       }) do
    Map.get(PluginDiscovery.shipped_modules(), plugin_id) == module
  end

  defp plugin_module_matches_source?(%PluginEntry{source: source})
       when source in [:project, :home],
       do: true

  defp valid_plugin_children?(:ignore), do: true
  defp valid_plugin_children?(children), do: is_map(children)

  defp valid_app_id?(app_id) when is_atom(app_id) and app_id not in [nil, true, false] do
    app_id not in [:none, :general] and
      Regex.match?(~r/^[a-z][a-z0-9_]*$/, Atom.to_string(app_id))
  end

  defp valid_app_id?(_app_id), do: false

  defp valid_memory_namespace?(nil, _app_id), do: true

  defp valid_memory_namespace?(
         %{app_id: app_id, namespace: namespace, writable: writable, description: description},
         app_id
       ) do
    proper_atom?(namespace) and is_boolean(writable) and is_binary(description)
  end

  defp valid_memory_namespace?(_namespace, _app_id), do: false

  defp valid_optional_module?(nil), do: true
  defp valid_optional_module?(module), do: proper_module?(module)

  defp valid_app_child_id?(nil), do: true
  defp valid_app_child_id?(child_id) when is_integer(child_id) or is_binary(child_id), do: true
  defp valid_app_child_id?(child_id) when is_atom(child_id), do: proper_atom?(child_id)

  defp valid_app_child_id?(child_id) when is_tuple(child_id) do
    child_id |> Tuple.to_list() |> Enum.all?(&valid_app_child_id?/1)
  end

  defp valid_app_child_id?(_child_id), do: false

  defp valid_app_child_pid?(value), do: value in [nil, :ignore] or is_pid(value)

  defp optional_string?(nil), do: true
  defp optional_string?(value), do: canonical_string?(value)

  defp module_list?(values) when is_list(values), do: Enum.all?(values, &proper_module?/1)
  defp module_list?(_values), do: false

  defp string_list?(values) when is_list(values), do: Enum.all?(values, &canonical_string?/1)
  defp string_list?(_values), do: false

  defp map_list?(values) when is_list(values), do: Enum.all?(values, &is_map/1)
  defp map_list?(_values), do: false

  defp proper_module?(value), do: proper_atom?(value)
  defp proper_atom?(value), do: is_atom(value) and value not in [nil, true, false]

  defp canonical_string?(value) when is_binary(value) do
    value != "" and String.valid?(value) and value == String.trim(value) and
      not Enum.any?(String.to_charlist(value), &(&1 in 0..0x1F or &1 == 0x7F))
  end

  defp canonical_string?(_value), do: false

  defp strict_intent_descriptors(apps, plugins, context, action_capabilities) do
    app_id_by_module = Map.new(apps, &{&1.module, &1.app_id})
    capability_by_name = Map.new(action_capabilities, &{&1.name, &1})

    app_sources =
      Enum.map(apps, fn app ->
        %{app_id: app.app_id, module: app.module, plugin_id: nil, source: :app}
      end)

    plugin_sources =
      plugins
      |> Enum.filter(&(&1.status == :enabled))
      |> Enum.reduce_while(
        {:ok, []},
        &collect_plugin_intent_sources(&1, &2, app_id_by_module)
      )

    with {:ok, plugin_sources} <- plugin_sources,
         sources = app_sources ++ Enum.reverse(plugin_sources),
         {:ok, descriptors} <-
           map_ok(
             sources,
             &strict_descriptors_from_source(&1, context, capability_by_name)
           ),
         {:ok, descriptors} <- reconcile_intent_descriptors(descriptors) do
      {:ok, descriptors}
    end
  end

  defp collect_plugin_intent_sources(plugin, {:ok, sources}, app_id_by_module) do
    plugin.apps
    |> Enum.reduce_while({:ok, sources}, fn module, {:ok, nested_sources} ->
      case Map.fetch(app_id_by_module, module) do
        {:ok, app_id} ->
          source = %{
            app_id: app_id,
            module: module,
            plugin_id: plugin.plugin_id,
            source: :plugin
          }

          {:cont, {:ok, [source | nested_sources]}}

        :error ->
          {:halt, {:error, :unstable_registry_capture}}
      end
    end)
    |> case do
      {:ok, next_sources} -> {:cont, {:ok, next_sources}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp strict_descriptors_from_source(source, context, capability_by_name) do
    module = source.module

    cond do
      not Code.ensure_loaded?(module) ->
        {:error, :unstable_registry_capture}

      not function_exported?(module, :intent_descriptors, 0) ->
        {:ok, []}

      true ->
        strict_loaded_descriptors(source, context, capability_by_name)
    end
  rescue
    _exception -> {:error, :unstable_registry_capture}
  catch
    _kind, _reason -> {:error, :unstable_registry_capture}
  end

  defp strict_loaded_descriptors(source, context, capability_by_name) do
    values = apply(source.module, :intent_descriptors, [])

    if is_list(values) do
      result =
        IntentDescriptor.normalize_many(
          values,
          [
            app_id: source.app_id,
            plugin_id: source.plugin_id,
            source: source.source,
            source_module: source.module
          ] ++ RegistryContext.take(context)
        )

      if Enum.all?(
           result.diagnostics,
           &intent_exposure_filter_diagnostic?(&1, source, capability_by_name)
         ) and
           Enum.all?(
             result.descriptors,
             &strict_descriptor?(&1, source, capability_by_name)
           ) and
           unique_intent_keys?(result.descriptors, result.diagnostics) do
        {:ok, result.descriptors}
      else
        {:error, :unstable_registry_capture}
      end
    else
      {:error, :unstable_registry_capture}
    end
  end

  defp strict_descriptor?(%IntentDescriptor{} = descriptor, source) do
    descriptor.app_id == source.app_id and descriptor.source == source.source and
      descriptor.source_module == source.module
  end

  defp strict_descriptor?(%IntentDescriptor{} = descriptor, source, capability_by_name) do
    if strict_descriptor?(descriptor, source) do
      case Map.fetch(capability_by_name, descriptor.action_name) do
        {:ok, %Capability{} = capability} ->
          descriptor.capability == Capability.summary(capability)

        :error ->
          safe_inert_handoff_descriptor?(descriptor, source)

        {:ok, _invalid_capability} ->
          false
      end
    else
      false
    end
  end

  defp strict_descriptor?(_descriptor, _source, _capability_by_name), do: false

  defp safe_inert_handoff_descriptor?(%IntentDescriptor{} = descriptor, source) do
    expected_capability = %{
      name: descriptor.action_name,
      registered?: false,
      permission: :read_only,
      exposure: :agent,
      execution_mode: :read_only,
      skill_backed?: false,
      confirmation: :not_required,
      resumable?: false,
      app_id: source.app_id
    }

    expected_capability =
      if is_binary(source.plugin_id) do
        Map.put(expected_capability, :plugin_id, source.plugin_id)
      else
        expected_capability
      end

    descriptor.handoff_required? == true and is_nil(descriptor.destination) and
      descriptor.capability == expected_capability
  end

  defp unique_intent_keys?(descriptors, diagnostics) do
    keys =
      Enum.map(descriptors, &{&1.app_id, &1.action_name}) ++
        Enum.flat_map(diagnostics, fn
          %{
            app_id: app_id,
            reason: {:action_not_agent_exposed, action_name}
          } ->
            [{app_id, action_name}]

          _diagnostic ->
            []
        end)

    MapSet.size(MapSet.new(keys)) == length(keys)
  end

  defp reconcile_intent_descriptors(descriptor_lists) do
    descriptor_lists
    |> List.flatten()
    |> Enum.reduce_while({:ok, [], %{}}, &reconcile_intent_descriptor/2)
    |> case do
      {:ok, ordered, _by_key} -> {:ok, Enum.reverse(ordered)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_intent_descriptor(descriptor, {:ok, ordered, by_key}) do
    key = {descriptor.app_id, descriptor.action_name}

    case Map.fetch(by_key, key) do
      :error ->
        {:cont, {:ok, [descriptor | ordered], Map.put(by_key, key, descriptor)}}

      {:ok, existing} ->
        reconcile_duplicate_intent(existing, descriptor, ordered, by_key)
    end
  end

  defp reconcile_duplicate_intent(existing, descriptor, ordered, by_key) do
    if dual_source_equivalent?(existing, descriptor) do
      {:cont, {:ok, ordered, by_key}}
    else
      {:halt, {:error, :unstable_registry_capture}}
    end
  end

  defp dual_source_equivalent?(%IntentDescriptor{} = left, %IntentDescriptor{} = right) do
    left.source != right.source and left.source_module == right.source_module and
      intrinsic_intent_descriptor(left) == intrinsic_intent_descriptor(right)
  end

  defp intrinsic_intent_descriptor(%IntentDescriptor{} = descriptor) do
    descriptor
    |> Map.from_struct()
    |> Map.delete(:source)
    |> Map.update!(:capability, fn capability ->
      Map.drop(capability, [:plugin_id, "plugin_id"])
    end)
  end

  # The frozen Extensions facade intentionally filters descriptors for
  # internal-only actions. Preserve only that proven semantic filter; every
  # callback, shape, lookup, ownership, and other normalization failure rejects
  # the complete capture instead of yielding a partial descriptor list.
  defp intent_exposure_filter_diagnostic?(
         %{
           kind: :invalid_intent_descriptor,
           reason: {:action_not_agent_exposed, action_name},
           app_id: app_id,
           source: source_kind,
           source_module: source_module,
           descriptor: descriptor
         },
         source,
         capability_by_name
       )
       when is_binary(action_name) and is_map(descriptor) do
    case Map.get(capability_by_name, action_name) do
      %{name: ^action_name, exposure: :internal} ->
        app_id == source.app_id and source_kind == source.source and
          source_module == source.module and
          map_field(descriptor, :action_name) == action_name and
          otherwise_valid_internal_descriptor?(descriptor, source)

      _capability ->
        false
    end
  end

  defp intent_exposure_filter_diagnostic?(_diagnostic, _source, _capability_by_name), do: false

  defp otherwise_valid_internal_descriptor?(descriptor, source) do
    inert_descriptor =
      descriptor
      |> Map.delete(:capability)
      |> Map.delete("capability")
      |> Map.put(:capability, %{registered?: false})

    opts = [
      app_id: source.app_id,
      plugin_id: source.plugin_id,
      source: source.source,
      source_module: source.module
    ]

    case IntentDescriptor.normalize(inert_descriptor, opts) do
      {:ok, normalized} -> strict_descriptor?(normalized, source)
      {:error, _diagnostic} -> false
    end
  end

  defp exact_extension_observation(apps, plugins, intent_descriptors) do
    enabled_plugins = Enum.filter(plugins, &(&1.status == :enabled))

    %{
      apps: apps,
      plugins: Enum.map(enabled_plugins, &%{plugin_id: &1.plugin_id}),
      actions:
        Enum.flat_map(apps, fn app ->
          Enum.map(app.actions, &%{source: :app, app_id: app.app_id, module: &1})
        end) ++
          Enum.flat_map(enabled_plugins, fn plugin ->
            Enum.map(plugin.actions, &%{source: :plugin, plugin_id: plugin.plugin_id, module: &1})
          end),
      skill_paths:
        Enum.flat_map(apps, fn app ->
          Enum.map(app.skill_paths, &%{source: :app, app_id: app.app_id, path: &1})
        end) ++
          Enum.flat_map(enabled_plugins, fn plugin ->
            Enum.map(
              plugin.skill_paths,
              &%{source: :plugin, plugin_id: plugin.plugin_id, path: &1}
            )
          end),
      child_specs:
        enabled_plugins
        |> Enum.reject(&(&1.children == :ignore))
        |> Enum.map(&%{plugin_id: &1.plugin_id, child_spec: &1.children}),
      intent_descriptors: intent_descriptors
    }
  end

  defp registry_pid(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :registry_unavailable}
    end
  rescue
    _exception -> {:error, :registry_unavailable}
  catch
    :exit, _reason -> {:error, :registry_unavailable}
  end

  defp registry_down?([app_monitor, plugin_monitor]) do
    receive do
      {:DOWN, ^app_monitor, :process, _pid, _reason} -> true
      {:DOWN, ^plugin_monitor, :process, _pid, _reason} -> true
    after
      0 -> false
    end
  end

  defp build_candidate(%Closed{} = closed, state) do
    with {:ok, enabled_plugins} <- enabled_plugin_entries(state.plugins),
         disabled_plugins = Enum.reject(state.plugins, &(&1.status == :enabled)),
         :ok <- validate_observation_closure(state, enabled_plugins, disabled_plugins),
         enabled_state = %{state | plugins: enabled_plugins},
         {:ok, static_count} <- infer_static_action_count(enabled_state),
         {:ok, bindings} <- build_action_bindings(enabled_state.action_capabilities, static_count),
         {:ok, action_projection} <-
           build_action_projection(enabled_plugins, bindings, static_count),
         {:ok, owner_index} <- build_legacy_owner_index(state.apps, enabled_plugins),
         {:ok, settings_projection} <-
           build_settings_projection(state.settings_fragments, owner_index),
         {:ok, surface_projection} <- build_surface_projection(state.apps, owner_index),
         {:ok, intent_projection} <-
           build_intent_projection(state.extensions.intent_descriptors, owner_index),
         {:ok, skill_projection} <- build_skill_projection(state.apps, enabled_plugins),
         {:ok, channel_projection} <- build_channel_projection(enabled_plugins),
         {:ok, app_projection} <-
           build_app_projection(
             state.apps,
             owner_index,
             action_projection.rows,
             settings_projection.refs_by_app_id,
             surface_projection.refs_by_app_id,
             skill_projection.refs_by_app_id,
             intent_projection.refs_by_app_id
           ),
         callback_rows =
           %{}
           |> put_callback_rows(:apps, app_projection.rows)
           |> put_callback_rows(:actions, action_projection.rows)
           |> put_callback_rows(:settings_fragments, settings_projection.rows)
           |> put_callback_rows(:channels, channel_projection.rows)
           |> put_callback_rows(:surfaces, surface_projection.rows)
           |> put_callback_rows(:skill_roots, skill_projection.rows),
         callback_rows =
           put_callback_rows(
             callback_rows,
             :intent_descriptors,
             intent_projection.rows
           ),
         :ok <-
           validate_callback_owner_closure(
             closed.rows,
             state.plugins,
             disabled_plugins,
             callback_rows
           ),
         {:ok, contributions} <-
           build_contributions(closed.rows, state.plugins, callback_rows),
         {:ok, child_diagnostics} <- child_spec_diagnostics(state.plugins) do
      {:ok,
       %Candidate{
         schema_version: 1,
         contributions: contributions,
         action_bindings: bindings,
         compatibility_aliases: action_projection.aliases,
         compatibility_diagnostics: child_diagnostics
       }}
    end
  rescue
    _error -> {:error, :unstable_registry_capture}
  end

  defp enabled_plugin_entries(plugins) when is_list(plugins) do
    plugins
    |> Enum.reduce_while({:ok, []}, fn
      %{status: :enabled} = plugin, {:ok, enabled} ->
        {:cont, {:ok, [plugin | enabled]}}

      %{status: :disabled}, {:ok, enabled} ->
        {:cont, {:ok, enabled}}

      _plugin, _accumulator ->
        {:halt, {:error, :unstable_registry_capture}}
    end)
    |> case do
      {:ok, enabled} -> {:ok, Enum.reverse(enabled)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_observation_closure(state, enabled_plugins, disabled_plugins) do
    enabled_ids = Enum.map(enabled_plugins, & &1.plugin_id)
    extension_ids = Enum.map(state.extensions.plugins, &map_field(&1, :plugin_id))

    cond do
      state.extensions.apps != state.apps ->
        {:error, :unstable_registry_capture}

      extension_ids != enabled_ids ->
        {:error, :unstable_registry_capture}

      disabled_plugin_state_leaked?(state, disabled_plugins) ->
        {:error, :unstable_registry_capture}

      true ->
        :ok
    end
  end

  defp disabled_plugin_state_leaked?(_state, []), do: false

  defp disabled_plugin_state_leaked?(state, disabled_plugins) do
    disabled_ids = MapSet.new(disabled_plugins, & &1.plugin_id)
    disabled_app_modules = disabled_plugins |> Enum.flat_map(& &1.apps) |> MapSet.new()

    Enum.any?(state.apps, &MapSet.member?(disabled_app_modules, &1.module)) or
      Enum.any?(state.action_capabilities, &MapSet.member?(disabled_ids, &1.plugin_id)) or
      disabled_settings_fragment_leaked?(state.settings_fragments, disabled_ids) or
      disabled_extension_state_leaked?(state.extensions, disabled_ids)
  end

  defp disabled_settings_fragment_leaked?(fragments, disabled_ids) do
    Enum.any?(fragments, &disabled_settings_fragment?(&1, disabled_ids))
  end

  defp disabled_settings_fragment?(%{source: :plugin, owner: owner}, disabled_ids) do
    case canonical_id(owner) do
      {:ok, owner_id} -> MapSet.member?(disabled_ids, owner_id)
      {:error, :unstable_registry_capture} -> true
    end
  end

  defp disabled_settings_fragment?(%{source: :plugin}, _disabled_ids), do: true
  defp disabled_settings_fragment?(%{source: _source}, _disabled_ids), do: false

  defp disabled_extension_state_leaked?(extensions, disabled_ids) do
    disabled_plugin_reference_leaked?(extensions.actions, disabled_ids) or
      disabled_plugin_reference_leaked?(extensions.skill_paths, disabled_ids) or
      disabled_plugin_reference_leaked?(extensions.child_specs, disabled_ids) or
      disabled_plugin_reference_leaked?(extensions.intent_descriptors, disabled_ids)
  end

  defp disabled_plugin_reference_leaked?(entries, disabled_ids) do
    Enum.any?(entries, &MapSet.member?(disabled_ids, Map.get(&1, :plugin_id)))
  end

  defp validate_callback_owner_closure(
         projection_rows,
         plugins,
         disabled_plugins,
         callback_rows
       ) do
    contribution_ids = Enum.map(projection_rows, & &1.id) ++ Enum.map(plugins, & &1.plugin_id)
    callback_owner_ids = Map.keys(callback_rows)
    contribution_id_set = MapSet.new(contribution_ids)
    disabled_ids = MapSet.new(disabled_plugins, & &1.plugin_id)

    cond do
      MapSet.size(contribution_id_set) != length(contribution_ids) ->
        {:error, :unstable_registry_capture}

      not MapSet.subset?(MapSet.new(callback_owner_ids), contribution_id_set) ->
        {:error, :unstable_registry_capture}

      Enum.any?(callback_owner_ids, &MapSet.member?(disabled_ids, &1)) ->
        {:error, :unstable_registry_capture}

      true ->
        :ok
    end
  end

  defp infer_static_action_count(state) do
    modules = Enum.map(state.action_capabilities, & &1.module)

    if modules == state.action_modules do
      raw_entries = raw_plugin_action_entries(state.plugins)

      0..length(modules)
      |> Enum.find(fn static_count ->
        static_modules = Enum.take(modules, static_count)
        expected_tail = effective_plugin_modules(raw_entries, static_modules)
        expected_tail == Enum.drop(modules, static_count)
      end)
      |> case do
        nil -> {:error, :unstable_registry_capture}
        static_count -> {:ok, static_count}
      end
    else
      {:error, :unstable_registry_capture}
    end
  end

  defp raw_plugin_action_entries(plugins) do
    Enum.flat_map(plugins, fn plugin ->
      Enum.map(plugin.actions, fn module ->
        %{plugin_id: plugin.plugin_id, module: module, name: normalize_action_name(module.name())}
      end)
    end)
  end

  defp effective_plugin_modules(entries, static_modules) do
    static_names = MapSet.new(Enum.map(static_modules, &normalize_action_name(&1.name())))
    static_modules = MapSet.new(static_modules)

    entries = Enum.reject(entries, &MapSet.member?(static_modules, &1.module))

    duplicate_names =
      entries
      |> Enum.map(& &1.name)
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Map.new()

    entries
    |> Enum.reject(fn entry ->
      MapSet.member?(static_names, entry.name) or Map.has_key?(duplicate_names, entry.name)
    end)
    |> Enum.map(& &1.module)
  end

  defp build_action_bindings(capabilities, static_count) do
    bindings =
      capabilities
      |> Enum.with_index(1)
      |> Enum.map(fn {capability, legacy_index} ->
        source_lane = if legacy_index <= static_count, do: :native_static, else: :legacy_plugin
        normalized_capability = normalize_capability(capability)
        input_schema_sha256 = schema_sha256(capability.module, :schema)
        output_schema_sha256 = schema_sha256(capability.module, :output_schema)

        m0_projection = %{
          "index" => legacy_index,
          "name" => capability.name,
          "module" => module_name(capability.module),
          "source_bucket" => m0_source_bucket(source_lane),
          "capability" => normalized_capability,
          "input_schema_sha256" => input_schema_sha256,
          "output_schema_sha256" => output_schema_sha256
        }

        %ActionBinding{
          schema_version: 1,
          module: capability.module,
          name: capability.name,
          source_lane: source_lane,
          legacy_index: legacy_index,
          registry_order: capability.module.registry_order(),
          normalized_capability: normalized_capability,
          m0_row_sha256: m0_sha256(m0_projection),
          input_schema_sha256: input_schema_sha256,
          output_schema_sha256: output_schema_sha256
        }
      end)

    {:ok, bindings}
  end

  defp build_action_projection(plugins, bindings, static_count) do
    static_bindings = Enum.take(bindings, static_count)
    plugin_bindings = Enum.drop(bindings, static_count)
    static_by_module = Map.new(static_bindings, &{&1.module, &1})
    plugin_by_module = Map.new(plugin_bindings, &{&1.module, &1})

    static_rows = Enum.map(static_bindings, &action_row(@residual_owner_id, &1, false))

    {plugin_rows, aliases} =
      Enum.reduce(plugins, {%{}, []}, fn plugin, {rows_by_owner, aliases} ->
        project_plugin_action_rows(
          plugin,
          {rows_by_owner, aliases},
          static_by_module,
          plugin_by_module
        )
      end)

    {:ok,
     %{
       rows: Map.put(plugin_rows, @residual_owner_id, static_rows),
       aliases: Enum.reverse(aliases)
     }}
  catch
    :unstable_action_projection -> {:error, :unstable_registry_capture}
  end

  defp project_plugin_action_rows(
         plugin,
         {rows_by_owner, aliases},
         static_by_module,
         plugin_by_module
       ) do
    {rows, new_aliases} =
      Enum.map_reduce(plugin.actions, [], fn module, alias_acc ->
        project_plugin_action_row(
          plugin.plugin_id,
          module,
          alias_acc,
          static_by_module,
          plugin_by_module
        )
      end)

    {Map.put(rows_by_owner, plugin.plugin_id, rows), Enum.reverse(new_aliases) ++ aliases}
  end

  defp project_plugin_action_row(
         plugin_id,
         module,
         aliases,
         static_by_module,
         plugin_by_module
       ) do
    case {Map.get(static_by_module, module), Map.get(plugin_by_module, module)} do
      {%ActionBinding{} = binding, nil} ->
        row = action_row(plugin_id, binding, true)
        alias_record = action_alias(plugin_id, binding)
        {row, [alias_record | aliases]}

      {nil, %ActionBinding{} = binding} ->
        {action_row(plugin_id, binding, false), aliases}

      _other ->
        throw(:unstable_action_projection)
    end
  end

  defp action_row(owner_id, binding, alias?) do
    payload_without_digest = %{
      "module" => module_name(binding.module),
      "name" => binding.name,
      "registry_order" => binding.registry_order
    }

    normalized =
      normalize_reference_row!(
        :action_ref_v1,
        payload_without_digest,
        action_source_authority(binding),
        "binding_sha256"
      )

    %Row{
      schema_version: 1,
      kind: :actions,
      owner_id: owner_id,
      identity: %{namespace: :action_name, value: binding.name},
      order: %{
        namespace: if(alias?, do: :alias_target, else: :registry_order),
        value: binding.registry_order
      },
      payload_schema: :action_ref_v1,
      payload: RowSchemas.canonical_projection(normalized),
      source_authority: RowSchemas.source_authority_projection(normalized),
      m0_payload_sha256: if(alias?, do: nil, else: binding.m0_row_sha256)
    }
  end

  defp action_alias(plugin_id, binding) do
    target = %Target{
      schema_version: 1,
      kind: :action,
      owner_id: @residual_owner_id,
      identity: binding.name
    }

    authority = action_source_authority(binding)

    %CompatibilityAlias{
      schema_version: 1,
      kind: :legacy_plugin,
      owner_id: plugin_id,
      target: target,
      module: binding.module,
      authority_sha256: sha256(@alias_digest_domain <> CanonicalJSON.encode(authority))
    }
  end

  defp action_source_authority(binding) do
    %{
      "kind" => "action",
      "module" => module_name(binding.module),
      "name" => binding.name,
      "normalized_capability" => m0_normalize(binding.normalized_capability),
      "input_schema_sha256" => binding.input_schema_sha256,
      "output_schema_sha256" => binding.output_schema_sha256
    }
  end

  defp build_legacy_owner_index(apps, plugins) do
    plugin_pairs =
      for plugin <- plugins,
          module <- plugin.apps do
        {module, plugin.plugin_id}
      end

    plugin_modules = Enum.map(plugin_pairs, &elem(&1, 0))
    registered_modules = Enum.map(apps, & &1.module)

    cond do
      MapSet.size(MapSet.new(plugin_modules)) != length(plugin_modules) ->
        {:error, :unstable_registry_capture}

      not MapSet.subset?(MapSet.new(plugin_modules), MapSet.new(registered_modules)) ->
        {:error, :unstable_registry_capture}

      true ->
        plugin_by_module = Map.new(plugin_pairs)

        by_module =
          Map.new(apps, fn app ->
            {app.module, Map.get(plugin_by_module, app.module, @residual_owner_id)}
          end)

        by_app_id = Map.new(apps, &{&1.app_id, Map.fetch!(by_module, &1.module)})
        app_id_by_module = Map.new(apps, &{&1.module, &1.app_id})

        if map_size(by_module) == length(apps) and map_size(by_app_id) == length(apps) and
             map_size(app_id_by_module) == length(apps) do
          {:ok, %{by_module: by_module, by_app_id: by_app_id, app_id_by_module: app_id_by_module}}
        else
          {:error, :unstable_registry_capture}
        end
    end
  end

  defp build_settings_projection(fragments, owner_index) do
    fragments
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{rows: %{}, refs_by_app_id: %{}}}, fn {fragment, index},
                                                                      {:ok, acc} ->
      project_settings_fragment(fragment, index, acc, owner_index)
    end)
    |> finalize_projection_rows()
  end

  defp project_settings_fragment(fragment, index, acc, owner_index) do
    with {:ok, owner_id} <- settings_pack_owner(fragment, owner_index),
         {:ok, source_owner_id} <- canonical_id(fragment.owner),
         {:ok, fragment_id} <- canonical_id(fragment.id) do
      source_authority = %{
        "fragment_id" => fragment_id,
        "legacy_owner_id" => source_owner_id,
        "source" => fragment.source,
        "group" => fragment.group,
        "schema_version" => fragment.schema_version,
        "schema" => closed_value_projection(fragment.schema, true),
        "defaults" => closed_value_projection(fragment.defaults, true),
        "safe_write_keys" => fragment.safe_write_keys,
        "metadata" => closed_value_projection(fragment.metadata, true)
      }

      normalized =
        normalize_reference_row!(
          :settings_fragment_ref_v1,
          %{
            "fragment_id" => fragment_id,
            "owner_id" => owner_id,
            "schema_version" => fragment.schema_version
          },
          source_authority,
          "projection_sha256"
        )

      payload = RowSchemas.canonical_projection(normalized)

      row = %Row{
        schema_version: 1,
        kind: :settings_fragments,
        owner_id: owner_id,
        identity: %{namespace: :fragment_id, value: fragment_id},
        order: %{namespace: :legacy_index, value: index},
        payload_schema: :settings_fragment_ref_v1,
        payload: payload,
        source_authority: RowSchemas.source_authority_projection(normalized),
        m0_payload_sha256: nil
      }

      {:cont,
       {:ok,
        %{
          rows: prepend_row(acc.rows, owner_id, row),
          refs_by_app_id: settings_fragment_refs(fragment, payload, acc.refs_by_app_id)
        }}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp settings_fragment_refs(%{source: :app} = fragment, payload, refs_by_app_id) do
    ref = %{
      "fragment_id" => payload["fragment_id"],
      "projection_sha256" => payload["projection_sha256"]
    }

    Map.update(refs_by_app_id, fragment.owner, [ref], &(&1 ++ [ref]))
  end

  defp settings_fragment_refs(_fragment, _payload, refs_by_app_id), do: refs_by_app_id

  defp settings_pack_owner(%{source: :core}, _owner_index), do: {:ok, @residual_owner_id}

  defp settings_pack_owner(%{source: :plugin, owner: owner}, _owner_index) do
    canonical_id(owner)
  end

  defp settings_pack_owner(%{source: :app, owner: app_id}, owner_index) do
    case Map.fetch(owner_index.by_app_id, app_id) do
      {:ok, owner_id} -> {:ok, owner_id}
      :error -> {:error, :unstable_registry_capture}
    end
  end

  defp settings_pack_owner(_fragment, _owner_index),
    do: {:error, :unstable_registry_capture}

  defp build_surface_projection(apps, owner_index) do
    entries =
      Enum.flat_map(apps, fn app ->
        Enum.map(app.provider_surfaces, &{app, &1})
      end)

    if Enum.any?(apps, &(Map.get(&1, :surfaces, []) != [])) do
      {:error, :unstable_registry_capture}
    else
      entries
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, %{rows: %{}, refs_by_app_id: %{}}}, fn {{app, surface}, index},
                                                                        {:ok, acc} ->
        project_surface(app, surface, index, acc, owner_index)
      end)
      |> finalize_projection_rows()
    end
  end

  defp project_surface(app, surface, index, acc, owner_index) do
    with true <- surface.app_id == app.app_id,
         {:ok, owner_id} <- fetch_app_owner(owner_index, app.module),
         {:ok, source_authority} <- surface_authority(surface) do
      normalized =
        normalize_reference_row!(
          :surface_ref_v1,
          %{
            "surface_id" => surface.id,
            "module" => app.surface_provider
          },
          source_authority,
          "projection_sha256"
        )

      payload = RowSchemas.canonical_projection(normalized)
      surface_id = payload["surface_id"]

      row = %Row{
        schema_version: 1,
        kind: :surfaces,
        owner_id: owner_id,
        identity: %{namespace: :surface_id, value: surface_id},
        order: %{namespace: :legacy_index, value: index},
        payload_schema: :surface_ref_v1,
        payload: payload,
        source_authority: RowSchemas.source_authority_projection(normalized),
        m0_payload_sha256: nil
      }

      ref = %{
        "surface_id" => surface_id,
        "projection_sha256" => payload["projection_sha256"]
      }

      {:cont,
       {:ok,
        %{
          rows: prepend_row(acc.rows, owner_id, row),
          refs_by_app_id: Map.update(acc.refs_by_app_id, app.app_id, [ref], &(&1 ++ [ref]))
        }}}
    else
      false -> {:halt, {:error, :unstable_registry_capture}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp surface_authority(%AllbertAssist.Surface{} = surface) do
    with {:ok, nodes} <- map_ok(surface.nodes, &surface_node_authority/1) do
      {:ok,
       %{
         "id" => surface.id,
         "app_id" => surface.app_id,
         "label" => surface.label,
         "path" => surface.path,
         "kind" => surface.kind,
         "zone" => surface.zone,
         "status" => surface.status,
         "nodes" => nodes,
         "fallback_text" => surface.fallback_text,
         "metadata" => closed_value_projection(surface.metadata, true)
       }}
    end
  end

  defp surface_authority(_surface), do: {:error, :unstable_registry_capture}

  defp surface_node_authority(%AllbertAssist.Surface.Node{} = node) do
    with {:ok, bindings} <- map_ok(node.bindings, &surface_binding_authority/1),
         {:ok, children} <- map_ok(node.children, &surface_node_authority/1) do
      {:ok,
       %{
         "id" => node.id,
         "component" => node.component,
         "props" => closed_value_projection(node.props, true),
         "bindings" => bindings,
         "children" => children
       }}
    end
  end

  defp surface_node_authority(_node), do: {:error, :unstable_registry_capture}

  defp surface_binding_authority(%AllbertAssist.Surface.ActionBinding{} = binding) do
    {:ok,
     %{
       "action_name" => binding.action_name,
       "action_module" => binding.action_module,
       "permission" => binding.permission,
       "app_id" => binding.app_id,
       "plugin_id" => binding.plugin_id,
       "confirmation_required?" => binding.confirmation_required?
     }}
  end

  defp surface_binding_authority(_binding), do: {:error, :unstable_registry_capture}

  defp build_intent_projection(descriptors, owner_index) do
    descriptors
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{rows: %{}, refs_by_app_id: %{}}}, fn {descriptor, index},
                                                                      {:ok, acc} ->
      with {:ok, registered_app_id} <-
             fetch_registered_app_id(owner_index, descriptor.source_module),
           true <- descriptor.app_id == registered_app_id,
           {:ok, owner_id} <- fetch_app_owner(owner_index, descriptor.source_module),
           {:ok, source_authority} <- intent_authority(descriptor) do
        normalized =
          normalize_reference_row!(
            :intent_descriptor_ref_v1,
            %{
              "intent_id" => descriptor.id,
              "module" => descriptor.source_module
            },
            source_authority,
            "projection_sha256"
          )

        payload = RowSchemas.canonical_projection(normalized)
        intent_id = payload["intent_id"]

        row = %Row{
          schema_version: 1,
          kind: :intent_descriptors,
          owner_id: owner_id,
          identity: %{namespace: :intent_id, value: intent_id},
          order: %{namespace: :legacy_index, value: index},
          payload_schema: :intent_descriptor_ref_v1,
          payload: payload,
          source_authority: RowSchemas.source_authority_projection(normalized),
          m0_payload_sha256: nil
        }

        ref = %{
          "intent_id" => intent_id,
          "projection_sha256" => payload["projection_sha256"]
        }

        {:cont,
         {:ok,
          %{
            rows: prepend_row(acc.rows, owner_id, row),
            refs_by_app_id:
              Map.update(acc.refs_by_app_id, descriptor.app_id, [ref], &(&1 ++ [ref]))
          }}}
      else
        false -> {:halt, {:error, :unstable_registry_capture}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> finalize_projection_rows()
  end

  defp intent_authority(%AllbertAssist.Intent.Descriptor{} = descriptor) do
    vocabulary = descriptor.vocabulary
    capability = descriptor.capability

    {:ok,
     %{
       "intent_id" => descriptor.id,
       "app_id" => descriptor.app_id,
       "action_name" => descriptor.action_name,
       "label" => descriptor.label,
       "source" => descriptor.source,
       "source_module" => descriptor.source_module,
       "destination" => descriptor.destination,
       "selection_policy" => descriptor.selection_policy,
       "examples" => descriptor.examples,
       "synonyms" => descriptor.synonyms,
       "required_slots" => descriptor.required_slots,
       "optional_slots" => descriptor.optional_slots,
       "slot_extractors" => descriptor.slot_extractors,
       "vocabulary" => %{
         "phrases" => map_field(vocabulary, :phrases, []),
         "negative_phrases" => map_field(vocabulary, :negative_phrases, []),
         "selection_phrases" => map_field(vocabulary, :selection_phrases, []),
         "selection_negative_phrases" => map_field(vocabulary, :selection_negative_phrases, []),
         "clarification_phrases" => map_field(vocabulary, :clarification_phrases, []),
         "allow_single_token_match" => map_field(vocabulary, :allow_single_token_match, true),
         "allow_required_slot_selection" =>
           map_field(vocabulary, :allow_required_slot_selection, false)
       },
       "handoff_required" => descriptor.handoff_required?,
       "routable_by_default" => descriptor.routable_by_default?,
       "capability" => %{
         "name" => map_field(capability, :name),
         "module" => map_field(capability, :module),
         "registered?" => map_field(capability, :registered?),
         "permission" => map_field(capability, :permission),
         "exposure" => map_field(capability, :exposure),
         "execution_mode" => map_field(capability, :execution_mode),
         "skill_backed?" => map_field(capability, :skill_backed?),
         "confirmation" => map_field(capability, :confirmation),
         "resumable?" => map_field(capability, :resumable?),
         "retry_safety" => map_field(capability, :retry_safety),
         "app_id" => map_field(capability, :app_id),
         "plugin_id" => map_field(capability, :plugin_id)
       }
     }}
  end

  defp intent_authority(_descriptor), do: {:error, :unstable_registry_capture}

  defp build_channel_projection(plugins) do
    entries =
      Enum.flat_map(plugins, fn plugin ->
        Enum.map(plugin.channels, &{plugin, &1})
      end)

    entries
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{rows: %{}}}, fn {{plugin, descriptor}, index}, {:ok, acc} ->
      with {:ok, source_authority} <- channel_authority(plugin, descriptor) do
        normalized =
          normalize_reference_row!(
            :channel_descriptor_v1,
            %{
              "channel_id" => map_field(descriptor, :channel_id),
              "module" => map_field(descriptor, :adapter)
            },
            source_authority,
            "projection_sha256"
          )

        payload = RowSchemas.canonical_projection(normalized)
        channel_id = payload["channel_id"]

        row = %Row{
          schema_version: 1,
          kind: :channels,
          owner_id: plugin.plugin_id,
          identity: %{namespace: :channel_id, value: channel_id},
          order: %{namespace: :legacy_index, value: index},
          payload_schema: :channel_descriptor_v1,
          payload: payload,
          source_authority: RowSchemas.source_authority_projection(normalized),
          m0_payload_sha256: nil
        }

        {:cont, {:ok, %{rows: prepend_row(acc.rows, plugin.plugin_id, row)}}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> finalize_projection_rows()
  end

  defp channel_authority(plugin, descriptor) when is_map(descriptor) do
    with {:ok, session_strategy} <-
           channel_session_strategy(map_field(descriptor, :session_strategy)),
         {:ok, child_spec} <- channel_child_spec(map_field(descriptor, :child_spec)) do
      plugin_id = map_field(descriptor, :plugin_id)

      if plugin_id == plugin.plugin_id do
        {:ok,
         %{
           "plugin_id" => plugin_id,
           "channel_id" => map_field(descriptor, :channel_id),
           "adapter" => map_field(descriptor, :adapter),
           "provider" => map_field(descriptor, :provider),
           "source" => map_field(descriptor, :source),
           "status" => map_field(descriptor, :status),
           "settings_prefix" => map_field(descriptor, :settings_prefix),
           "identity_map_key" => map_field(descriptor, :identity_map_key),
           "primitives" => map_field(descriptor, :primitives, []),
           "threading" => map_field(descriptor, :threading),
           "streaming" => map_field(descriptor, :streaming),
           "session_strategy" => session_strategy,
           "trust_class" => map_field(descriptor, :trust_class),
           "secret_refs" => map_field(descriptor, :secret_refs, []),
           "summary_fields" => map_field(descriptor, :summary_fields, []),
           "can_create_thread" => map_field(descriptor, :can_create_thread),
           "reply_key_type" => map_field(descriptor, :reply_key_type),
           "quote_ttl_ms" => map_field(descriptor, :quote_ttl_ms),
           "status_update_mode" => map_field(descriptor, :status_update_mode),
           "child_spec" => child_spec
         }}
      else
        {:error, :unstable_registry_capture}
      end
    end
  end

  defp channel_authority(_plugin, _descriptor), do: {:error, :unstable_registry_capture}

  defp channel_session_strategy(nil), do: {:ok, nil}

  defp channel_session_strategy({strategy, opts}) when is_atom(strategy) and is_list(opts) do
    if Keyword.keyword?(opts) do
      options =
        Enum.map(opts, fn {key, value} ->
          %{
            "key" => key,
            "value" => closed_value_projection(value, true)
          }
        end)

      {:ok, %{"strategy" => strategy, "options" => options}}
    else
      {:error, :unstable_registry_capture}
    end
  end

  defp channel_session_strategy(_strategy), do: {:error, :unstable_registry_capture}

  defp channel_child_spec(nil), do: {:ok, nil}

  defp channel_child_spec({module, options}) when is_atom(module) and is_list(options) do
    {:ok,
     %{
       "kind" => "module_options",
       "module" => module,
       "options" => closed_value_projection(options, true)
     }}
  end

  defp channel_child_spec(_child_spec), do: {:error, :unstable_registry_capture}

  defp build_app_projection(
         apps,
         owner_index,
         action_rows,
         settings_refs,
         surface_refs,
         skill_refs,
         intent_refs
       ) do
    with {:ok, action_index} <- app_action_index(action_rows) do
      refs = %{
        settings: settings_refs,
        surfaces: surface_refs,
        skills: skill_refs,
        intents: intent_refs
      }

      apps
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, %{rows: %{}}}, fn {app, index}, {:ok, acc} ->
        project_app(app, index, acc, owner_index, action_index, refs)
      end)
      |> finalize_projection_rows()
    end
  end

  defp project_app(app, index, acc, owner_index, action_index, refs) do
    with {:ok, owner_id} <- fetch_app_owner(owner_index, app.module),
         {:ok, action_refs} <- app_action_refs(app.actions, action_index),
         {:ok, source_authority} <-
           app_authority(
             app,
             action_refs,
             Map.get(refs.settings, app.app_id, []),
             Map.get(refs.surfaces, app.app_id, []),
             Map.get(refs.skills, app.app_id, []),
             Map.get(refs.intents, app.app_id, [])
           ) do
      normalized =
        normalize_reference_row!(
          :app_descriptor_v1,
          %{
            "module" => app.module,
            "app_id" => app.app_id
          },
          source_authority,
          "contract_sha256"
        )

      payload = RowSchemas.canonical_projection(normalized)
      app_id = payload["app_id"]

      row = %Row{
        schema_version: 1,
        kind: :apps,
        owner_id: owner_id,
        identity: %{namespace: :app_id, value: app_id},
        order: %{namespace: :legacy_index, value: index},
        payload_schema: :app_descriptor_v1,
        payload: payload,
        source_authority: RowSchemas.source_authority_projection(normalized),
        m0_payload_sha256: nil
      }

      {:cont, {:ok, %{rows: prepend_row(acc.rows, owner_id, row)}}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp app_action_index(action_rows) do
    action_rows
    |> Enum.flat_map(fn {_owner_id, rows} -> rows end)
    |> Enum.reduce_while({:ok, %{}}, fn row, {:ok, index} ->
      module = row.payload["module"]

      ref = %{
        "module" => module,
        "name" => row.payload["name"],
        "binding_sha256" => row.payload["binding_sha256"]
      }

      case Map.fetch(index, module) do
        :error -> {:cont, {:ok, Map.put(index, module, ref)}}
        {:ok, ^ref} -> {:cont, {:ok, index}}
        {:ok, _different} -> {:halt, {:error, :unstable_registry_capture}}
      end
    end)
  end

  defp app_action_refs(actions, action_index) do
    actions
    |> Enum.reduce_while({:ok, []}, fn module, {:ok, refs} ->
      case Map.fetch(action_index, module_name(module)) do
        {:ok, ref} -> {:cont, {:ok, [ref | refs]}}
        :error -> {:halt, {:error, :unstable_registry_capture}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp app_authority(
         app,
         action_refs,
         settings_refs,
         surface_refs,
         skill_refs,
         intent_refs
       ) do
    memory_namespace =
      case app.memory_namespace do
        nil ->
          nil

        namespace when is_map(namespace) ->
          %{
            "app_id" => map_field(namespace, :app_id),
            "namespace" => map_field(namespace, :namespace),
            "writable" => map_field(namespace, :writable),
            "description" => map_field(namespace, :description)
          }

        _other ->
          throw(:invalid_app_authority)
      end

    surface_catalog =
      Enum.map(app.surface_catalog, fn entry ->
        %{
          "component" => map_field(entry, :component),
          "allowed_props" => map_field(entry, :allowed_props, []),
          "allowed_bindings" => map_field(entry, :allowed_bindings, [])
        }
      end)

    {:ok,
     %{
       "app_id" => app.app_id,
       "module" => app.module,
       "display_name" => app.display_name,
       "version" => app.version,
       "actions" => action_refs,
       "agents" => app.agents,
       "signals" => %{
         "emits" => map_field(app.signals, :emits, []),
         "subscribes" => map_field(app.signals, :subscribes, [])
       },
       "memory_namespace" => memory_namespace,
       "surface_provider" => app.surface_provider,
       "surface_refs" => surface_refs,
       "surface_catalog" => surface_catalog,
       "skill_root_refs" => skill_refs,
       "settings_fragment_refs" => settings_refs,
       "intent_descriptor_refs" => intent_refs,
       "child_id" => child_id_projection(app.child_id),
       "metadata" => closed_value_projection(app.metadata, true)
     }}
  catch
    :invalid_app_authority -> {:error, :unstable_registry_capture}
  end

  defp child_id_projection(value) when is_integer(value) or is_binary(value), do: value

  defp child_id_projection(value) when is_atom(value) and value not in [nil, true, false],
    do: value

  defp child_id_projection(value) when is_tuple(value) do
    %{"tuple" => value |> Tuple.to_list() |> Enum.map(&child_id_projection/1)}
  end

  defp child_id_projection(nil), do: nil
  defp child_id_projection(_value), do: raise(ArgumentError)

  defp fetch_app_owner(owner_index, module) do
    case Map.fetch(owner_index.by_module, module) do
      {:ok, owner_id} -> {:ok, owner_id}
      :error -> {:error, :unstable_registry_capture}
    end
  end

  defp fetch_registered_app_id(owner_index, module) do
    case Map.fetch(owner_index.app_id_by_module, module) do
      {:ok, app_id} -> {:ok, app_id}
      :error -> {:error, :unstable_registry_capture}
    end
  end

  defp prepend_row(rows, owner_id, row),
    do: Map.update(rows, owner_id, [row], &[row | &1])

  defp finalize_projection_rows({:ok, %{rows: rows} = projection}) do
    {:ok,
     %{
       projection
       | rows: Map.new(rows, fn {owner_id, values} -> {owner_id, Enum.reverse(values)} end)
     }}
  end

  defp finalize_projection_rows({:error, reason}), do: {:error, reason}

  defp map_ok(values, mapper) when is_list(values) and is_function(mapper, 1) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, mapped} ->
      case mapper.(value) do
        {:ok, next} -> {:cont, {:ok, [next | mapped]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, mapped} -> {:ok, Enum.reverse(mapped)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp map_ok(_values, _mapper), do: {:error, :unstable_registry_capture}

  defp map_field(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    atom_value = Map.fetch(map, key)
    string_value = Map.fetch(map, Atom.to_string(key))

    case {atom_value, string_value} do
      {{:ok, value}, :error} -> value
      {:error, {:ok, value}} -> value
      {:error, :error} -> default
      {{:ok, value}, {:ok, value}} -> value
      {{:ok, _left}, {:ok, _right}} -> raise ArgumentError
    end
  end

  defp canonical_id(value) when is_atom(value) and value not in [nil, true, false],
    do: {:ok, Atom.to_string(value)}

  defp canonical_id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp canonical_id(_value), do: {:error, :unstable_registry_capture}

  defp closed_value_projection(value, _allow_atoms)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value),
       do: value

  defp closed_value_projection(value, _allow_atoms) when is_binary(value),
    do: symbolize_allbert_home(value)

  defp closed_value_projection(value, true)
       when is_atom(value) and value not in [nil, true, false],
       do: module_name(value)

  defp closed_value_projection(value, allow_atoms) when is_list(value),
    do: Enum.map(value, &closed_value_projection(&1, allow_atoms))

  defp closed_value_projection(%{__struct__: _module}, _allow_atoms),
    do: raise(ArgumentError)

  defp closed_value_projection(value, allow_atoms) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, normalized ->
      normalized_key =
        case key do
          key when is_atom(key) -> Atom.to_string(key)
          key when is_binary(key) -> key
          _other -> raise ArgumentError
        end

      if Map.has_key?(normalized, normalized_key), do: raise(ArgumentError)

      Map.put(
        normalized,
        normalized_key,
        closed_value_projection(nested, allow_atoms)
      )
    end)
  end

  defp closed_value_projection(_value, _allow_atoms), do: raise(ArgumentError)

  defp symbolize_allbert_home(value) do
    home = AllbertAssist.Paths.home()

    cond do
      not is_binary(home) or home == "" ->
        value

      value == home ->
        "<ALLBERT_HOME>"

      String.starts_with?(value, home <> "/") ->
        "<ALLBERT_HOME>" <> String.replace_prefix(value, home, "")

      true ->
        value
    end
  end

  defp build_skill_projection(apps, plugins) do
    with :ok <- validate_skill_declaration_closure(apps, plugins) do
      plugins
      |> Enum.reduce_while({:ok, %{rows: %{}, refs_by_app_id: %{}}}, fn plugin, {:ok, acc} ->
        project_plugin_skills(plugin, acc, apps)
      end)
    end
  end

  defp project_plugin_skills(plugin, acc, apps) do
    case project_plugin_skill_roots(plugin, apps) do
      {:ok, rows, refs} ->
        next = %{
          rows: Map.put(acc.rows, plugin.plugin_id, rows),
          refs_by_app_id: merge_ordered_refs(acc.refs_by_app_id, refs)
        }

        {:cont, {:ok, next}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp validate_skill_declaration_closure(apps, plugins) do
    module_plugins = Enum.reject(plugins, &is_nil(&1.module))
    app_modules = Enum.flat_map(module_plugins, & &1.apps)

    cond do
      MapSet.size(MapSet.new(app_modules)) != length(app_modules) ->
        {:error, :unstable_registry_capture}

      Enum.any?(apps, fn app -> app.skill_paths != [] and app.module not in app_modules end) ->
        {:error, :unstable_registry_capture}

      Enum.all?(module_plugins, &matching_skill_declarations?(&1, apps)) ->
        :ok

      true ->
        {:error, :unstable_registry_capture}
    end
  end

  defp matching_skill_declarations?(plugin, apps) do
    app_paths =
      apps
      |> Enum.filter(&(&1.module in plugin.apps))
      |> Enum.flat_map(& &1.skill_paths)
      |> Enum.map(&Path.expand/1)

    plugin_paths = Enum.map(plugin.skill_paths, &Path.expand/1)

    app_paths == plugin_paths and
      MapSet.size(MapSet.new(plugin_paths)) == length(plugin_paths)
  end

  defp project_plugin_skill_roots(%PluginEntry{module: nil} = plugin, _apps) do
    project_declared_skill_roots(plugin)
  end

  defp project_plugin_skill_roots(plugin, apps) do
    plugin.skill_paths
    |> Enum.reduce_while({:ok, [], %{}, MapSet.new()}, fn path, {:ok, rows, refs, identities} ->
      with {:ok, relative_path} <- repository_relative_skill_path(plugin, path),
           {:ok, app_id} <- owning_skill_app_id(plugin, apps, path),
           root_id = "#{app_id}:#{Path.basename(relative_path)}",
           false <- MapSet.member?(identities, root_id) do
        normalized =
          normalize_reference_row!(
            :skill_root_v1,
            %{
              "root_id" => root_id,
              "relative_path" => relative_path,
              "trust_policy" => plugin.trust_status
            },
            %{},
            "projection_sha256"
          )

        payload = RowSchemas.canonical_projection(normalized)

        row = %Row{
          schema_version: 1,
          kind: :skill_roots,
          owner_id: plugin.plugin_id,
          identity: %{namespace: :root_id, value: root_id},
          order: %{namespace: :lexical, value: root_id},
          payload_schema: :skill_root_v1,
          payload: payload,
          source_authority: RowSchemas.source_authority_projection(normalized),
          m0_payload_sha256: nil
        }

        ref = %{
          "owner_id" => plugin.plugin_id,
          "root_id" => root_id,
          "projection_sha256" => payload["projection_sha256"]
        }

        {:cont,
         {:ok, [row | rows], Map.update(refs, app_id, [ref], &(&1 ++ [ref])),
          MapSet.put(identities, root_id)}}
      else
        true -> {:halt, {:error, :unstable_registry_capture}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows, refs, _identities} -> {:ok, Enum.reverse(rows), refs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp project_declared_skill_roots(plugin) do
    plugin.skill_paths
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn path, {:ok, rows, identities} ->
      with {:ok, relative_path} <- declared_skill_path(plugin, path),
           root_id = "#{plugin.plugin_id}:#{relative_path}",
           false <- MapSet.member?(identities, root_id) do
        normalized =
          normalize_reference_row!(
            :skill_root_v1,
            %{
              "root_id" => root_id,
              "relative_path" => relative_path,
              "trust_policy" => plugin.trust_status
            },
            %{},
            "projection_sha256"
          )

        row = %Row{
          schema_version: 1,
          kind: :skill_roots,
          owner_id: plugin.plugin_id,
          identity: %{namespace: :root_id, value: root_id},
          order: %{namespace: :lexical, value: root_id},
          payload_schema: :skill_root_v1,
          payload: RowSchemas.canonical_projection(normalized),
          source_authority: RowSchemas.source_authority_projection(normalized),
          m0_payload_sha256: nil
        }

        {:cont, {:ok, [row | rows], MapSet.put(identities, root_id)}}
      else
        true -> {:halt, {:error, :unstable_registry_capture}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows, _identities} -> {:ok, Enum.reverse(rows), %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp declared_skill_path(%PluginEntry{root_path: root_path, plugin_id: plugin_id}, path)
       when is_binary(root_path) and is_binary(path) do
    root = Path.expand(root_path)
    expanded = Path.expand(path)

    if expanded == root or String.starts_with?(expanded, root <> "/") do
      inside_root = Path.relative_to(expanded, root)

      logical_segments =
        case inside_root do
          "." -> ["plugins", plugin_id]
          relative -> ["plugins", plugin_id | Path.split(relative)]
        end

      if Enum.any?(logical_segments, &(&1 in ["", ".", ".."])) do
        {:error, :unstable_registry_capture}
      else
        {:ok, Enum.join(logical_segments, "/")}
      end
    else
      {:error, :unstable_registry_capture}
    end
  end

  defp declared_skill_path(_plugin, _path), do: {:error, :unstable_registry_capture}

  defp repository_relative_skill_path(_plugin, path) when is_binary(path) do
    segments = Path.split(path)

    plugin_markers =
      segments
      |> Enum.with_index()
      |> Enum.filter(fn {segment, _index} -> segment == "plugins" end)

    case plugin_markers do
      [{"plugins", index}] ->
        relative_path = segments |> Enum.drop(index) |> Path.join()

        if Path.type(relative_path) == :relative and Path.basename(relative_path) == "skills" do
          {:ok, relative_path}
        else
          {:error, :unstable_registry_capture}
        end

      _other ->
        {:error, :unstable_registry_capture}
    end
  end

  defp repository_relative_skill_path(_plugin, _path),
    do: {:error, :unstable_registry_capture}

  defp owning_skill_app_id(plugin, apps, path) do
    path = Path.expand(path)

    matches =
      Enum.filter(apps, fn app ->
        app.module in plugin.apps and
          Enum.count(app.skill_paths, &(Path.expand(&1) == path)) == 1
      end)

    case matches do
      [%{app_id: app_id}] -> {:ok, app_id}
      _other -> {:error, :unstable_registry_capture}
    end
  end

  defp merge_ordered_refs(left, right) do
    Map.merge(left, right, fn _app_id, left_refs, right_refs -> left_refs ++ right_refs end)
  end

  defp put_callback_rows(callback_rows, callback, rows_by_owner) do
    Enum.reduce(rows_by_owner, callback_rows, fn {owner_id, rows}, acc ->
      Map.update(acc, owner_id, %{callback => rows}, &Map.put(&1, callback, rows))
    end)
  end

  defp build_contributions(projection_rows, plugins, callback_rows) do
    compiled =
      Enum.map(projection_rows, fn projection ->
        %Contribution{
          schema_version: 1,
          implementation_module: projection.descriptor_module,
          owner: %Owner{
            schema_version: 1,
            kind: :compiled_pack,
            id: projection.id,
            application: projection.application
          },
          descriptor: projection.descriptor,
          source_lane: :native,
          owner_order: %Order{
            schema_version: 1,
            namespace: :compiled_pack,
            value: projection.registry_order
          },
          compatibility: %Compatibility{
            schema_version: 1,
            kind: :native,
            legacy_id: nil,
            alias_of: nil,
            trust: :trusted,
            enabled: true
          },
          callbacks:
            empty_callbacks()
            |> Map.merge(Map.get(callback_rows, projection.id, %{}))
        }
      end)

    legacy =
      plugins
      |> Enum.with_index(1)
      |> Enum.map(fn {plugin, legacy_index} ->
        plugin_contribution(plugin, legacy_index, Map.get(callback_rows, plugin.plugin_id, %{}))
      end)

    {:ok, compiled ++ legacy}
  end

  defp empty_callbacks, do: Map.new(@callback_names, &{&1, []})

  defp plugin_contribution(%PluginEntry{module: nil} = plugin, _legacy_index, callback_rows) do
    %Contribution{
      schema_version: 1,
      implementation_module: nil,
      owner: %Owner{
        schema_version: 1,
        kind: :declared_pack,
        id: plugin.plugin_id,
        application: nil
      },
      descriptor: nil,
      source_lane: :declared,
      owner_order: %Order{
        schema_version: 1,
        namespace: :declared_pack,
        value: plugin.plugin_id
      },
      compatibility: %Compatibility{
        schema_version: 1,
        kind: :declared,
        legacy_id: nil,
        alias_of: nil,
        trust: plugin.trust_status,
        enabled: plugin.status == :enabled
      },
      callbacks: empty_callbacks() |> Map.merge(callback_rows)
    }
  end

  defp plugin_contribution(plugin, legacy_index, callback_rows) do
    %Contribution{
      schema_version: 1,
      implementation_module: plugin.module,
      owner: %Owner{
        schema_version: 1,
        kind: :legacy_plugin,
        id: plugin.plugin_id,
        application: nil
      },
      descriptor: nil,
      source_lane: :legacy_plugin,
      owner_order: %Order{
        schema_version: 1,
        namespace: :legacy_plugin,
        value: legacy_index
      },
      compatibility: %Compatibility{
        schema_version: 1,
        kind: :legacy_plugin,
        legacy_id: plugin.plugin_id,
        alias_of: nil,
        trust: plugin.trust_status,
        enabled: plugin.status == :enabled
      },
      callbacks: empty_callbacks() |> Map.merge(callback_rows)
    }
  end

  defp child_spec_diagnostics(plugins) do
    diagnostics =
      Enum.flat_map(plugins, fn
        %{status: :disabled} = plugin -> [child_spec_diagnostic(plugin)]
        %{status: :enabled, children: :ignore} -> []
        %{status: :enabled} = plugin -> [child_spec_diagnostic(plugin)]
      end)

    {:ok, diagnostics}
  end

  defp child_spec_diagnostic(%{status: :enabled} = plugin) do
    if not is_map(plugin.children), do: raise(ArgumentError)
    child_spec = Supervisor.child_spec(plugin.children, [])

    %CompatibilityDiagnostic{
      schema_version: 1,
      code: :child_spec,
      severity: :warning,
      path: plugin_diagnostic_path(plugin.plugin_id, "children"),
      owner: plugin_owner_ref(plugin),
      detail: %{child_spec: project_child_spec(child_spec)}
    }
  end

  defp child_spec_diagnostic(%{status: :disabled} = plugin) do
    %CompatibilityDiagnostic{
      schema_version: 1,
      code: :disabled_plugin,
      severity: :warning,
      path: plugin_diagnostic_path(plugin.plugin_id, "status"),
      owner: plugin_owner_ref(plugin),
      detail: %{source: plugin.source, status: :disabled}
    }
  end

  defp plugin_diagnostic_path(plugin_id, field) do
    [
      field_segment("plugins"),
      %PathSegment{schema_version: 1, kind: :identity, value: plugin_id},
      field_segment(field)
    ]
  end

  defp plugin_owner_ref(%PluginEntry{module: nil, plugin_id: plugin_id}) do
    %OwnerRef{
      schema_version: 1,
      kind: :declared_pack,
      id: plugin_id
    }
  end

  defp plugin_owner_ref(%PluginEntry{plugin_id: plugin_id}) do
    %OwnerRef{
      schema_version: 1,
      kind: :legacy_plugin,
      id: plugin_id
    }
  end

  defp project_child_spec(spec) when is_map(spec) do
    {start_module, start_function, start_arity, start_args_sha256} =
      case Map.get(spec, :start) do
        {module, function, args}
        when is_atom(module) and module not in [nil, true, false] and is_atom(function) and
               function not in [nil, true, false] and is_list(args) ->
          normalized_args = strict_child_normalize(args)

          {
            module_name(module),
            Atom.to_string(function),
            length(args),
            sha256(@child_args_digest_domain <> CanonicalJSON.encode(normalized_args))
          }

        nil ->
          {nil, nil, nil, nil}
      end

    %AllbertAssist.Pack.ChildSpecProjection{
      schema_version: 1,
      id: canonical_child_id(Map.get(spec, :id)),
      start_module: start_module,
      start_function: start_function,
      start_arity: start_arity,
      start_args_sha256: start_args_sha256,
      restart: restart_projection(Map.get(spec, :restart)),
      shutdown: shutdown_projection(Map.get(spec, :shutdown)),
      type: child_type_projection(Map.get(spec, :type))
    }
  end

  defp canonical_child_id(nil), do: nil
  defp canonical_child_id(value) when is_integer(value), do: value
  defp canonical_child_id(value) when is_binary(value) and value != "", do: value

  defp canonical_child_id(value) when is_atom(value) and value not in [true, false],
    do: module_name(value)

  defp canonical_child_id(value) when is_tuple(value) do
    %{"tuple" => value |> Tuple.to_list() |> Enum.map(&canonical_child_id/1)}
  end

  defp canonical_child_id(_value), do: raise(ArgumentError)

  defp strict_child_normalize(nil), do: nil
  defp strict_child_normalize(true), do: true
  defp strict_child_normalize(false), do: false

  defp strict_child_normalize(value) when is_integer(value) or is_float(value), do: value

  defp strict_child_normalize(value) when is_binary(value) do
    if Path.type(value) == :absolute, do: raise(ArgumentError), else: value
  end

  defp strict_child_normalize(value) when is_atom(value), do: module_name(value)

  defp strict_child_normalize(value) when is_list(value),
    do: Enum.map(value, &strict_child_normalize/1)

  defp strict_child_normalize(value) when is_tuple(value) do
    %{"tuple" => value |> Tuple.to_list() |> Enum.map(&strict_child_normalize/1)}
  end

  defp strict_child_normalize(%_{}), do: raise(ArgumentError)

  defp strict_child_normalize(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, normalized ->
      key = strict_child_key(key)

      if Map.has_key?(normalized, key), do: raise(ArgumentError)
      Map.put(normalized, key, strict_child_normalize(nested))
    end)
  end

  defp strict_child_normalize(_value), do: raise(ArgumentError)

  defp strict_child_key(value) when is_binary(value) do
    if Path.type(value) == :absolute, do: raise(ArgumentError), else: value
  end

  defp strict_child_key(value) when is_atom(value), do: module_name(value)
  defp strict_child_key(_value), do: raise(ArgumentError)

  defp normalize_capability(capability) do
    capability
    |> Map.from_struct()
    |> Map.take([
      :app_id,
      :confirmation,
      :execution_mode,
      :exposure,
      :notes,
      :permission,
      :plugin_id,
      :resumable?,
      :retry_safety,
      :skill_backed?
    ])
  end

  defp schema_sha256(module, function) do
    value = if function_exported?(module, function, 0), do: apply(module, function, []), else: nil
    m0_sha256(value)
  end

  defp m0_source_bucket(:native_static), do: "static"
  defp m0_source_bucket(:legacy_plugin), do: "plugin_append"

  defp normalize_reference_row!(schema, payload_without_digest, source_authority, digest_field) do
    placeholder = Map.put(payload_without_digest, digest_field, String.duplicate("0", 64))

    digest =
      RowSchemas.reference_digest_for!(schema, %RowSchemas.Input{
        payload: placeholder,
        source_authority: source_authority
      })

    RowSchemas.normalize!(schema, %RowSchemas.Input{
      payload: Map.put(payload_without_digest, digest_field, digest),
      source_authority: source_authority
    })
  end

  defp m0_sha256(value), do: value |> m0_normalize() |> CanonicalJSON.encode() |> sha256()

  defp m0_normalize(nil), do: nil
  defp m0_normalize(true), do: true
  defp m0_normalize(false), do: false
  defp m0_normalize(value) when is_integer(value) or is_float(value), do: value
  defp m0_normalize(value) when is_binary(value), do: value

  defp m0_normalize(%Regex{} = regex),
    do: %{"$regex" => Regex.source(regex), "opts" => regex.opts}

  defp m0_normalize(%MapSet{} = set),
    do: set |> MapSet.to_list() |> Enum.map(&m0_normalize/1) |> Enum.sort()

  defp m0_normalize(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> m0_normalize()
    |> Map.put("$struct", module_name(struct.__struct__))
  end

  defp m0_normalize(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {normalize_m0_key(key), m0_normalize(nested)} end)
  end

  defp m0_normalize(value) when is_list(value), do: Enum.map(value, &m0_normalize/1)

  defp m0_normalize(value) when is_tuple(value),
    do: %{"$tuple" => value |> Tuple.to_list() |> m0_normalize()}

  defp m0_normalize(value) when is_function(value) do
    %{
      "$function" => module_name(:erlang.fun_info(value, :module) |> elem(1)),
      "name" => value |> :erlang.fun_info(:name) |> elem(1) |> Atom.to_string(),
      "arity" => value |> :erlang.fun_info(:arity) |> elem(1)
    }
  end

  defp m0_normalize(value) when is_pid(value), do: "<PID>"
  defp m0_normalize(value) when is_reference(value), do: "<REFERENCE>"
  defp m0_normalize(value) when is_port(value), do: "<PORT>"
  defp m0_normalize(value) when is_atom(value), do: module_name(value)
  defp m0_normalize(value), do: inspect(value)

  defp normalize_m0_key(key) when is_binary(key), do: key
  defp normalize_m0_key(key) when is_atom(key), do: module_name(key)
  defp normalize_m0_key(key), do: key |> m0_normalize() |> inspect()

  defp normalize_action_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp module_name(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp restart_projection(nil), do: nil

  defp restart_projection(value) when value in [:permanent, :transient, :temporary],
    do: Atom.to_string(value)

  defp restart_projection(_value), do: raise(ArgumentError)

  defp child_type_projection(nil), do: nil

  defp child_type_projection(value) when value in [:worker, :supervisor],
    do: Atom.to_string(value)

  defp child_type_projection(_value), do: raise(ArgumentError)

  defp shutdown_projection(value) when is_integer(value) and value >= 0, do: value
  defp shutdown_projection(nil), do: nil

  defp shutdown_projection(value) when value in [:brutal_kill, :infinity],
    do: Atom.to_string(value)

  defp shutdown_projection(_value), do: raise(ArgumentError)

  defp sha256(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp capture_error(code, path, detail) do
    {:error, {:capture_failed, [diagnostic(code, path, detail)]}}
  end

  defp diagnostic(code, path, detail) do
    %ValidationDiagnostic{
      schema_version: 1,
      code: code,
      path: path,
      owner: nil,
      detail: detail
    }
  end

  defp field_segment(value) do
    %PathSegment{schema_version: 1, kind: :field, value: value}
  end

  defp value_kind(value) when is_boolean(value), do: "boolean"
  defp value_kind(value) when is_atom(value), do: "atom"
  defp value_kind(value) when is_binary(value), do: "string"
  defp value_kind(value) when is_integer(value), do: "integer"
  defp value_kind(value) when is_float(value), do: "float"
  defp value_kind(value) when is_map(value), do: "map"
  defp value_kind(value) when is_list(value), do: "list"
  defp value_kind(value) when is_tuple(value), do: "tuple"
  defp value_kind(value) when is_pid(value), do: "pid"
  defp value_kind(value) when is_port(value), do: "port"
  defp value_kind(value) when is_reference(value), do: "reference"
  defp value_kind(value) when is_function(value), do: "function"
  defp value_kind(_value), do: "term"
end
