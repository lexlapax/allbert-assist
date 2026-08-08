defmodule AllbertAssist.Extensions.Registry do
  @moduledoc """
  Unified discovery facade for compiled app and plugin contributions.

  Apps and plugins remain distinct registries with distinct authority. This
  module only provides one read path for downstream workspace panels, theming,
  dynamic trials, and generator planning.
  """

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Pack.ActionProjection
  alias AllbertAssist.Intent.Descriptor
  alias AllbertAssist.Pack.{PathSegment, ValidationDiagnostic}
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.RegistryContext

  @type contribution_summary :: %{
          apps: [map()],
          plugins: [map()],
          surfaces: [map()],
          surface_providers: [surface_provider()],
          intent_descriptors: [map()],
          actions: [map()],
          skill_paths: [skill_path()],
          settings_schema: [map()],
          child_specs: [child_spec_contribution()],
          diagnostics: diagnostics()
        }
  @type surface_provider :: %{
          required(:app_id) => atom(),
          required(:catalog) => [map()],
          required(:module) => module(),
          required(:surfaces) => [map()]
        }
  @type skill_path :: %{
          required(:app_id) => atom(),
          required(:path) => term(),
          required(:plugin_id) => binary(),
          required(:source) => atom(),
          required(:trust_status) => atom()
        }
  @type child_spec_contribution :: %{
          required(:child_spec) => term(),
          required(:plugin_id) => binary()
        }
  @type diagnostics :: %{required(:apps) => map(), required(:plugins) => map()}

  @spec contributions(Keyword.t()) :: contribution_summary()
  def contributions(opts \\ []) do
    %{
      apps: registered_apps(opts),
      plugins: registered_plugins(opts),
      surfaces: registered_surfaces(opts),
      surface_providers: registered_surface_providers(opts),
      intent_descriptors: registered_intent_descriptors(opts),
      actions: registered_actions(opts),
      skill_paths: registered_skill_paths(opts),
      settings_schema: registered_settings_schema(opts),
      child_specs: registered_child_specs(opts),
      diagnostics: diagnostics(opts)
    }
  end

  @spec registered_apps(Keyword.t()) :: [map()]
  def registered_apps(opts \\ []), do: AppRegistry.registered_apps(app_opts(opts))

  @spec registered_plugins(Keyword.t()) :: [map()]
  def registered_plugins(opts \\ []) do
    opts
    |> plugin_opts()
    |> PluginRegistry.registered_plugins()
    |> Enum.map(&plugin_summary/1)
  end

  @spec registered_surfaces(Keyword.t()) :: [map()]
  def registered_surfaces(opts \\ []), do: AppRegistry.registered_surfaces(app_opts(opts))

  @spec registered_surface_providers(Keyword.t()) :: [surface_provider()]
  def registered_surface_providers(opts \\ []),
    do: AppRegistry.registered_surface_providers(app_opts(opts))

  @spec registered_intent_descriptors(Keyword.t()) :: [Descriptor.t()]
  def registered_intent_descriptors(opts \\ []) do
    opts
    |> intent_descriptor_sources()
    |> Enum.flat_map(&descriptors_from_source(&1, RegistryContext.take(opts)))
    |> Enum.uniq_by(&{&1.app_id, &1.action_name})
  end

  @doc """
  Normalize intent descriptors from sealed App/Plugin metadata entries.

  The action capability lookup is built from the pure static and supplied
  Plugin projections; this function never reads a live contribution registry.
  Invalid compiled callbacks or descriptor rows reject the complete input.
  """
  @spec intent_descriptors_from_entries([map()], [map()]) ::
          {:ok, [Descriptor.t()]} | {:error, [ValidationDiagnostic.t()]}
  def intent_descriptors_from_entries(app_entries, plugin_entries)
      when is_list(app_entries) and is_list(plugin_entries) do
    with {:ok, action_projection} <- ActionProjection.metadata(app_entries, plugin_entries),
         {:ok, sources} <- descriptor_sources_from_entries(app_entries, plugin_entries),
         {:ok, descriptors} <- normalize_descriptor_sources(sources, action_projection) do
      {:ok, Enum.uniq_by(descriptors, &{&1.app_id, &1.action_name})}
    end
  end

  def intent_descriptors_from_entries(_app_entries, _plugin_entries),
    do: {:error, [candidate_diagnostic(:invalid_candidate_entries)]}

  @spec registered_actions(Keyword.t()) :: [map()]
  def registered_actions(opts \\ []) do
    app_actions =
      opts
      |> registered_apps()
      |> Enum.flat_map(fn app ->
        app
        |> Map.get(:actions, [])
        |> Enum.map(&%{source: :app, app_id: app.app_id, module: &1})
      end)

    plugin_actions =
      opts
      |> plugin_opts()
      |> PluginRegistry.registered_plugins()
      |> Enum.flat_map(fn plugin ->
        Enum.map(
          plugin.actions,
          &%{
            source: :plugin,
            plugin_id: plugin.plugin_id,
            trust_status: plugin.trust_status,
            module: &1
          }
        )
      end)

    app_actions ++ plugin_actions
  end

  defp intent_descriptor_sources(opts) do
    app_sources =
      opts
      |> registered_apps()
      |> Enum.map(fn app ->
        %{
          app_id: app.app_id,
          module: app.module,
          source: :app
        }
      end)

    plugin_sources =
      opts
      |> plugin_opts()
      |> PluginRegistry.registered_plugins()
      |> Enum.flat_map(fn plugin ->
        Enum.map(plugin.apps, fn module ->
          %{
            app_id: app_id_for_module(module),
            module: module,
            plugin_id: plugin.plugin_id,
            source: :plugin
          }
        end)
      end)

    app_sources ++ plugin_sources
  end

  defp descriptors_from_source(%{module: module} = source, registry) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :intent_descriptors, 0) do
      module
      |> apply(:intent_descriptors, [])
      |> Descriptor.normalize_many(
        [
          app_id: source.app_id,
          plugin_id: Map.get(source, :plugin_id),
          source: source.source,
          source_module: module
        ] ++ registry
      )
      |> Map.fetch!(:descriptors)
    else
      []
    end
  rescue
    _exception -> []
  catch
    :exit, _reason -> []
  end

  defp descriptors_from_source(_source, _registry), do: []

  defp descriptor_sources_from_entries(app_entries, plugin_entries) do
    with {:ok, app_sources, app_modules} <- app_descriptor_sources(app_entries),
         {:ok, plugin_sources} <- plugin_descriptor_sources(plugin_entries, app_modules) do
      {:ok, app_sources ++ plugin_sources}
    end
  end

  defp app_descriptor_sources(entries) do
    entries
    |> Enum.reduce_while({:ok, [], %{}}, fn app, {:ok, sources, modules} ->
      app_id = Map.get(app, :app_id)
      module = Map.get(app, :module)

      if is_atom(app_id) and is_atom(module) and not Map.has_key?(modules, module) do
        source = %{app_id: app_id, module: module, source: :app}
        {:cont, {:ok, [source | sources], Map.put(modules, module, app_id)}}
      else
        {:halt, {:error, [candidate_diagnostic(:invalid_app_descriptor_source)]}}
      end
    end)
    |> then(fn
      {:ok, sources, modules} -> {:ok, Enum.reverse(sources), modules}
      error -> error
    end)
  end

  defp plugin_descriptor_sources(entries, app_modules) do
    entries
    |> Enum.reduce_while({:ok, []}, fn plugin, {:ok, sources} ->
      plugin_id = Map.get(plugin, :plugin_id)
      apps = Map.get(plugin, :apps, [])

      cond do
        Map.get(plugin, :status) != :enabled ->
          {:cont, {:ok, sources}}

        not is_binary(plugin_id) or plugin_id == "" or not is_list(apps) ->
          {:halt, {:error, [candidate_diagnostic(:invalid_plugin_descriptor_source)]}}

        true ->
          case Enum.reduce_while(apps, {:ok, sources}, fn module, {:ok, acc} ->
                 case Map.fetch(app_modules, module) do
                   {:ok, app_id} ->
                     {:cont,
                      {:ok,
                       [
                         %{app_id: app_id, module: module, plugin_id: plugin_id, source: :plugin}
                         | acc
                       ]}}

                   :error ->
                     {:halt, {:error, [candidate_diagnostic(:dangling_plugin_app)]}}
                 end
               end) do
            {:ok, next} -> {:cont, {:ok, next}}
            error -> {:halt, error}
          end
      end
    end)
    |> then(fn
      {:ok, sources} -> {:ok, Enum.reverse(sources)}
      error -> error
    end)
  end

  defp normalize_descriptor_sources(sources, action_projection) do
    capability_projection =
      action_projection.effective
      |> Map.new(fn action ->
        capability =
          action.normalized_capability
          |> Map.put(:name, action.name)
          |> Map.put(:module, action.module)
          |> Map.put(:registered?, true)
          |> Map.put(:app_id, action.app_id)
          |> Map.put(:plugin_id, action.plugin_id)

        {action.name, capability}
      end)

    sources
    |> Enum.reduce_while({:ok, []}, fn %{module: module} = source, {:ok, descriptors} ->
      cond do
        not Code.ensure_loaded?(module) ->
          {:halt, {:error, [candidate_diagnostic(:invalid_intent_descriptor_source)]}}

        not function_exported?(module, :intent_descriptors, 0) ->
          {:cont, {:ok, descriptors}}

        true ->
          case apply(module, :intent_descriptors, []) do
            values when is_list(values) ->
              normalized =
                Descriptor.normalize_many(
                  values,
                  app_id: source.app_id,
                  plugin_id: Map.get(source, :plugin_id),
                  source: source.source,
                  source_module: module,
                  capability_projection: capability_projection,
                  candidate_app_ids: sources |> Enum.map(& &1.app_id) |> Enum.uniq()
                )

              if ignorable_candidate_diagnostics?(normalized.diagnostics) do
                {:cont, {:ok, descriptors ++ normalized.descriptors}}
              else
                {:halt, {:error, [candidate_diagnostic(:invalid_intent_descriptor)]}}
              end

            _other ->
              {:halt, {:error, [candidate_diagnostic(:invalid_intent_descriptor_source)]}}
          end
      end
    end)
  rescue
    _exception -> {:error, [candidate_diagnostic(:invalid_intent_descriptor_source)]}
  catch
    :exit, _reason -> {:error, [candidate_diagnostic(:invalid_intent_descriptor_source)]}
  end

  # M0 intentionally retains diagnostics for declarations that target
  # internal-only actions while excluding those descriptors from the effective
  # routing projection. Candidate construction preserves that frozen split;
  # every other normalization diagnostic remains a fail-closed compiled-input
  # error.
  defp ignorable_candidate_diagnostics?(diagnostics) when is_list(diagnostics) do
    Enum.all?(diagnostics, fn
      %{reason: {:action_not_agent_exposed, name}} when is_binary(name) -> true
      _other -> false
    end)
  end

  defp candidate_diagnostic(reason) do
    %ValidationDiagnostic{
      schema_version: 1,
      code: :invalid_value,
      path: [%PathSegment{schema_version: 1, kind: :field, value: "intent_descriptors"}],
      owner: nil,
      detail: %{reason: reason}
    }
  end

  defp app_id_for_module(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :app_id, 0) do
      apply(module, :app_id, [])
    end
  rescue
    _exception -> nil
  catch
    :exit, _reason -> nil
  end

  @spec registered_skill_paths(Keyword.t()) :: [skill_path()]
  def registered_skill_paths(opts \\ []) do
    AppRegistry.registered_skill_paths(app_opts(opts)) ++
      PluginRegistry.registered_skill_paths(plugin_opts(opts))
  end

  @spec registered_settings_schema(Keyword.t()) :: [map()]
  def registered_settings_schema(opts \\ []) do
    AppRegistry.registered_settings_schema(app_opts(opts)) ++
      PluginRegistry.registered_settings_schema(plugin_opts(opts))
  end

  @spec registered_child_specs(Keyword.t()) :: [child_spec_contribution()]
  def registered_child_specs(opts \\ []) do
    PluginRegistry.registered_child_specs(plugin_opts(opts))
  end

  @spec diagnostics(Keyword.t()) :: diagnostics()
  def diagnostics(opts \\ []) do
    %{
      apps: AppRegistry.diagnostics(app_opts(opts)),
      plugins: PluginRegistry.diagnostics(plugin_opts(opts))
    }
  end

  defp plugin_summary(plugin) do
    %{
      plugin_id: plugin.plugin_id,
      display_name: plugin.display_name,
      version: plugin.version,
      kind: plugin.kind,
      source: plugin.source,
      status: plugin.status,
      trust_status: plugin.trust_status,
      apps: plugin.apps,
      actions: plugin.actions,
      channels: plugin.channels,
      skill_paths: plugin.skill_paths,
      settings_schema: plugin.settings_schema,
      diagnostics: plugin.diagnostics
    }
  end

  defp app_opts(opts), do: Keyword.get(opts, :app, [])
  defp plugin_opts(opts), do: Keyword.get(opts, :plugin, [])
end
