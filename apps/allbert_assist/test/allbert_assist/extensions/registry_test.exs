defmodule AllbertAssist.Extensions.RegistryTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.DevGates.V14M0RegistryLedger
  alias AllbertAssist.Extensions.Registry
  alias AllbertAssist.Plugin.Entry
  alias AllbertAssist.TestSupport.RegistryIsolationFixtures, as: Fixtures

  setup do
    context = Fixtures.start_isolated_registries(:extensions_registry)
    assert "stocksage" = Fixtures.register_plugin!(context, StockSage.Plugin)
    assert :stocksage = Fixtures.register_app!(context, StockSage.App)

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

    assert "m7.example" = Fixtures.register_plugin!(context, entry)
    {:ok, registry_context: context}
  end

  test "aggregates app and plugin contribution surfaces through one facade", %{
    registry_context: context
  } do
    contributions = Registry.contributions(context)

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

  test "aggregates actions, settings, skill roots, and child specs", %{
    registry_context: context
  } do
    assert Enum.any?(
             Registry.registered_actions(context),
             &(&1.source == :app and &1.app_id == :stocksage and
                 &1.module == StockSage.Actions.RunAnalysis)
           )

    assert Enum.any?(
             Registry.registered_actions(context),
             &(&1.source == :plugin and &1.plugin_id == "m7.example" and
                 &1.module == AllbertAssist.Actions.Intent.DirectAnswer)
           )

    assert Enum.any?(
             Registry.registered_settings_schema(context),
             &(Map.get(&1, :key) == "m7.example.enabled")
           )

    assert Enum.any?(
             Registry.registered_skill_paths(context),
             &(Map.get(&1, :plugin_id) == "m7.example" and
                 Map.get(&1, :path) == "/tmp/m7-example-skills")
           )

    assert Enum.any?(
             Registry.registered_child_specs(context),
             &(Map.get(&1, :plugin_id) == "m7.example")
           )
  end

  test "shipped restoration preserves the complete frozen registry projection" do
    context = Fixtures.start_shipped_registries(:extensions_shipped_projection)
    contributions = Registry.contributions(context)

    assert length(contributions.apps) == 6
    assert length(contributions.plugins) == 13
    assert :ok = V14M0RegistryLedger.check!()
  end
end
