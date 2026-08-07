defmodule AllbertAssist.TestSupport.ShippedRegistries do
  @moduledoc false

  # v1.0.2 M2 drift-fix: serial tests that clear the GLOBAL App/Plugin
  # registries must restore the FULL shipped baseline, never a snapshot or a
  # hand-maintained subset. A snapshot taken while the registry was already
  # partial (a prior test's damage) re-applies that damage on exit, and a
  # hand-maintained list silently drifts as plugins ship — both leave later
  # serial tests with missing registrations (ADR 0031 then fails Settings
  # validation, descriptors vanish, SurfacePolicy degrades). Watchdog-traced
  # to allbert_plugins_test's telegram+email-only restore and
  # StockSageRegistryCase's snapshot restore. Mirrors
  # operator_mutation_actions_test's proven restore_shipped_* logic.

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Plugin.Discovery, as: PluginDiscovery
  alias AllbertAssist.Plugin.Paths, as: PluginPaths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

  @shipped_discovery_settings %{
    "enabled" => [],
    "disabled" => [],
    "scan_paths" => ["./plugins", "<ALLBERT_HOME>/plugins"],
    "trusted_project_roots" => [],
    "load_policy" => "shipped_and_skill_only"
  }

  @doc "Clear both global registries and restore the full shipped baseline."
  def restore! do
    PluginRegistry.clear()

    shipped_modules = PluginDiscovery.shipped_modules() |> Map.values() |> MapSet.new()

    PluginDiscovery.discover(
      project_root: PluginPaths.project_root(),
      settings: @shipped_discovery_settings
    )
    |> Enum.each(fn
      {:module, module, opts} ->
        if MapSet.member?(shipped_modules, module) do
          {:ok, _plugin_id} = PluginRegistry.register_module(module, opts)
        end

      {:diagnostic, key, diagnostics} ->
        :ok = PluginRegistry.put_diagnostics(to_string(key), diagnostics)

      {:entry, _entry} ->
        :ok
    end)

    AppRegistry.clear()

    plugin_apps =
      PluginRegistry.registered_plugins()
      |> Enum.flat_map(& &1.apps)

    [AllbertAssist.App.CoreApp | plugin_apps]
    |> Enum.uniq()
    |> Enum.each(fn module ->
      {:ok, _app_id} = AppRegistry.register(module)
    end)

    :ok
  end
end
