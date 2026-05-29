defmodule AllbertAssist.Extensions.RegistryTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Extensions.Registry
  alias AllbertAssist.Plugin.Entry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

  setup do
    original_plugins = PluginRegistry.registered_plugins()
    PluginRegistry.clear()

    assert {:ok, "stocksage"} = PluginRegistry.register_module(StockSage.Plugin)

    app_registered? = AppRegistry.known_app_id?(:stocksage)

    unless app_registered? do
      assert {:ok, :stocksage} = AppRegistry.register(StockSage.App)
    end

    entry = %Entry{
      plugin_id: "m7.example",
      display_name: "M7 Example",
      version: "0.1.0",
      kind: "test",
      source: :project,
      status: :enabled,
      trust_status: :trusted,
      actions: [AllbertAssist.Actions.Intent.DirectAnswer],
      skill_paths: ["/tmp/m7-example-skills"],
      settings_schema: [%{key: "m7.example.enabled", type: :boolean, default: true}],
      children: {Task, fn -> :ok end}
    }

    assert {:ok, "m7.example"} = PluginRegistry.register_entry(entry)

    on_exit(fn ->
      PluginRegistry.clear()
      Enum.each(original_plugins, &PluginRegistry.register_entry/1)
      unless app_registered?, do: AppRegistry.unregister(:stocksage)
    end)

    :ok
  end

  test "aggregates app and plugin contribution surfaces through one facade" do
    contributions = Registry.contributions()

    assert Enum.any?(contributions.apps, &(&1.app_id == :stocksage))
    assert Enum.any?(contributions.plugins, &(&1.plugin_id == "m7.example"))
    assert Enum.any?(contributions.surface_providers, &(&1.app_id == :stocksage))

    assert Enum.any?(
             contributions.intent_descriptors,
             &(&1.app_id == :stocksage and &1.action_name == "run_analysis")
           )

    assert Enum.any?(contributions.surfaces, &(&1.app_id == :stocksage))
    assert contributions.diagnostics.apps |> is_map()
    assert contributions.diagnostics.plugins |> is_map()
  end

  test "aggregates actions, settings, skill roots, and child specs" do
    assert Enum.any?(
             Registry.registered_actions(),
             &(&1.source == :app and &1.app_id == :stocksage and
                 &1.module == StockSage.Actions.RunAnalysis)
           )

    assert Enum.any?(
             Registry.registered_actions(),
             &(&1.source == :plugin and &1.plugin_id == "m7.example" and
                 &1.module == AllbertAssist.Actions.Intent.DirectAnswer)
           )

    assert Enum.any?(
             Registry.registered_settings_schema(),
             &(Map.get(&1, :key) == "m7.example.enabled")
           )

    assert Enum.any?(
             Registry.registered_skill_paths(),
             &(Map.get(&1, :plugin_id) == "m7.example" and
                 Map.get(&1, :path) == "/tmp/m7-example-skills")
           )

    assert Enum.any?(
             Registry.registered_child_specs(),
             &(Map.get(&1, :plugin_id) == "m7.example")
           )
  end
end
