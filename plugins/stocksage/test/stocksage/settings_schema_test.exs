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

  test "v0.22 bridge settings register with their defaults" do
    schema = Schema.runtime_schema()

    assert schema["stocksage.bridge_enabled"].default == true
    assert schema["stocksage.python_path"].default == "python3"
    assert schema["stocksage.bridge_timeout_ms"].default == 300_000
    assert schema["stocksage.bridge_max_output_bytes"].default == 1_048_576
    assert schema["stocksage.analysis_engine"].default == "tradingagents"
    assert schema["stocksage.analysis_engine"].allowed_values == ["tradingagents"]
  end

  test "permissions.stocksage_analyze registers with needs_confirmation default and floor" do
    schema = Schema.runtime_schema()
    entry = schema["permissions.stocksage_analyze"]

    assert entry.default == "needs_confirmation"
    assert entry.allowed_values == ["needs_confirmation", "denied"]
    refute "allowed" in entry.allowed_values
  end
end
