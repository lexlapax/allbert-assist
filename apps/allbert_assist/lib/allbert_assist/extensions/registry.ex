defmodule AllbertAssist.Extensions.Registry do
  @moduledoc """
  Unified discovery facade for compiled app and plugin contributions.

  Apps and plugins remain distinct registries with distinct authority. This
  module only provides one read path for downstream workspace panels, theming,
  dynamic trials, and generator planning.
  """

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

  @type contribution_summary :: %{
          apps: [map()],
          plugins: [map()],
          surfaces: [map()],
          surface_providers: [surface_provider()],
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
