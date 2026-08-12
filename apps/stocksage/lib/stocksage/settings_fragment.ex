defmodule StockSage.SettingsFragment do
  @moduledoc """
  Pack `FragmentOwner` for StockSage.

  A re-declaration rather than a reshape: `StockSage.Settings.Fragment`
  (extracted from the plugin's former `settings_schema/0` body) is still the
  single definition, and this owner derives from it instead of copying the
  entries. A second literal copy is exactly how the two drift.

  `id`, `owner` and `source` reproduce what
  `AllbertAssist.Settings.Fragments.plugin_fragments/1` produced from the
  plugin path before the move, so stored identity survives without a
  migration. `owner` is the plugin_id STRING, not an atom -- a plugin-sourced
  fragment resolves by owner id, unlike an app-sourced fragment.
  """

  @behaviour AllbertAssist.Settings.FragmentOwner

  alias AllbertAssist.Settings.Fragment
  alias AllbertAssist.Settings.Schema
  alias StockSage.Settings.Fragment, as: Source

  # Every key came from `settings_schema/0` with no `writable?` declared, which
  # `AllbertAssist.Settings.Schema.plugin_schema_attrs/2` defaulted to `true` --
  # so all 37 keys are safe-write rows. The indices continue the global
  # sequence at the value the operator reserved for this extraction.
  @safe_write_rows [
    {900, "stocksage.web.enabled"},
    {901, "stocksage.web.progress_stream_enabled"},
    {902, "stocksage.import.default_user"},
    {903, "stocksage.import.batch_size"},
    {904, "stocksage.import.unknown_tables_as_warnings"},
    {905, "stocksage.list.max_results"},
    {906, "stocksage.queue.default_priority"},
    {907, "stocksage.outcomes.default_holding_period_days"},
    {908, "stocksage.outcomes.resolver_cadence"},
    {909, "stocksage.outcomes.neutral_return_threshold_pct"},
    {910, "stocksage.reflections.enabled"},
    {911, "stocksage.reflections.max_chars"},
    {912, "stocksage.bridge_enabled"},
    {913, "stocksage.python_path"},
    {914, "stocksage.bridge_timeout_ms"},
    {915, "stocksage.bridge_max_output_bytes"},
    {916, "stocksage.analysis_engine"},
    {917, "stocksage.native_engine_enabled"},
    {918, "stocksage.native_model_profile"},
    {919, "stocksage.native_llm_enabled"},
    {920, "stocksage.native_model_profile_market_context"},
    {921, "stocksage.native_model_profile_news_sentiment"},
    {922, "stocksage.native_model_profile_fundamentals"},
    {923, "stocksage.native_model_profile_bull_thesis"},
    {924, "stocksage.native_model_profile_bear_thesis"},
    {925, "stocksage.native_model_profile_risk_aggressive"},
    {926, "stocksage.native_model_profile_risk_conservative"},
    {927, "stocksage.native_model_profile_risk_neutral"},
    {928, "stocksage.native_model_profile_research_manager"},
    {929, "stocksage.native_model_profile_trader_plan"},
    {930, "stocksage.native_model_profile_decision_synthesizer"},
    {931, "stocksage.native_agent_timeout_ms"},
    {932, "stocksage.native_max_debate_rounds"},
    {933, "stocksage.native_max_risk_rounds"},
    {934, "stocksage.native_evidence_mode"},
    {935, "stocksage.native_parity_variance"},
    {936, "stocksage.python_comparison_enabled"}
  ]

  @impl true
  def safe_write_rows, do: @safe_write_rows

  @impl true
  @spec fragment() :: Fragment.t()
  def fragment do
    schema =
      Map.new(Source.schema(), fn %{key: key} = entry ->
        {key, entry_fields(entry)}
      end)

    Fragment.new!(%{
      id: "plugin:stocksage",
      owner: "stocksage",
      source: :plugin,
      group: :plugins,
      schema: schema,
      defaults: defaults(schema),
      safe_write_keys: Enum.map(@safe_write_rows, &elem(&1, 1)),
      metadata: %{
        display_name: "StockSage",
        trust_status: :trusted,
        source: :shipped
      }
    })
  end

  defp defaults(schema) do
    Enum.reduce(schema, %{}, fn {key, entry}, acc ->
      Schema.put_dotted(acc, key, Map.fetch!(entry, :default))
    end)
  end

  # The fragment contract accepts a closed field set and rejects anything else
  # with "unknown settings schema entry fields". Plugin-path schemas carry extras
  # -- `:description` most often -- so project onto the accepted set rather than
  # deleting whichever key happened to fail first.
  defp entry_fields(entry) do
    Map.take(entry, [:type, :default, :writable?, :sensitive?, :allowed_values, :min, :max])
  end
end
