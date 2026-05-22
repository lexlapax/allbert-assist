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
    assert schema["stocksage.web.enabled"].default == true
    assert schema["stocksage.web.progress_stream_enabled"].default == true
    assert Schema.safe_write_key?("stocksage.queue.default_priority")
    assert Schema.safe_write_key?("stocksage.web.enabled")
    assert Schema.safe_write_key?("stocksage.web.progress_stream_enabled")
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

  test "v0.25 native agent settings register with defaults and validation bounds" do
    schema = Schema.runtime_schema()

    assert schema["stocksage.native_engine_enabled"].default == true
    assert schema["stocksage.native_llm_enabled"].default == true
    assert schema["stocksage.native_model_profile"].default == "fast"
    assert schema["stocksage.native_model_profile_market_context"].default == nil
    assert schema["stocksage.native_model_profile_risk_aggressive"].default == "slow"
    assert schema["stocksage.native_model_profile_research_manager"].default == "slow"
    assert schema["stocksage.native_model_profile_trader_plan"].default == "slow"
    assert schema["stocksage.native_model_profile_decision_synthesizer"].default == "slow"
    assert schema["stocksage.native_agent_timeout_ms"].default == 180_000
    assert schema["stocksage.native_max_debate_rounds"].min == 1
    assert schema["stocksage.native_max_debate_rounds"].max == 5
    assert schema["stocksage.native_max_risk_rounds"].min == 1
    assert schema["stocksage.native_max_risk_rounds"].max == 3

    assert schema["stocksage.native_evidence_mode"].allowed_values == [
             "live",
             "fixture",
             "compare"
           ]

    assert schema["stocksage.native_parity_variance"].min == 0.0
    assert schema["stocksage.native_parity_variance"].max == 1.0
    assert schema["stocksage.python_comparison_enabled"].default == true

    assert Schema.safe_write_key?("stocksage.native_model_profile_market_context")
    assert Schema.safe_write_key?("stocksage.native_model_profile_research_manager")
    assert Schema.safe_write_key?("stocksage.native_model_profile_trader_plan")
    assert Schema.safe_write_key?("stocksage.native_llm_enabled")
    assert Schema.safe_write_key?("stocksage.native_agent_timeout_ms")
    assert Schema.safe_write_key?("stocksage.native_evidence_mode")
  end

  test "permissions.stocksage_analyze registers with needs_confirmation default and floor" do
    schema = Schema.runtime_schema()
    entry = schema["permissions.stocksage_analyze"]

    assert entry.default == "needs_confirmation"
    assert entry.allowed_values == ["needs_confirmation", "denied"]
    refute "allowed" in entry.allowed_values
  end

  test "permissions.stocksage_evidence_fetch registers for bounded evidence actions" do
    schema = Schema.runtime_schema()
    entry = schema["permissions.stocksage_evidence_fetch"]

    assert entry.default == "allowed"
    assert entry.allowed_values == ["allowed", "needs_confirmation", "denied"]
    assert Schema.safe_write_key?("permissions.stocksage_evidence_fetch")
  end
end
