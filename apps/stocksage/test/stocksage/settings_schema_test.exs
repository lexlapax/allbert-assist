defmodule StockSage.SettingsSchemaTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings.Schema

  setup do
    PluginRegistry.register_module(StockSage.Plugin)
    :ok
  end

  test "StockSage plugin settings are visible in the merged runtime schema" do
    schema = Schema.runtime_schema()

    assert schema["stocksage.import.default_user"].default == "local"
    assert schema["stocksage.import.batch_size"].default == 500
    assert schema["stocksage.import.unknown_tables_as_warnings"].default == true
    assert schema["stocksage.list.max_results"].default == 50
    assert schema["stocksage.queue.default_priority"].allowed_values == ["low", "normal", "high"]
    assert Schema.safe_write_key?("stocksage.queue.default_priority")
  end
end
