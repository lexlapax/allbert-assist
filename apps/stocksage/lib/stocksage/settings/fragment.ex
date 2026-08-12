defmodule StockSage.Settings.Fragment do
  @moduledoc """
  Settings Central schema fragment for StockSage.

  v1.4 M13 moved this list out of `StockSage.Plugin.settings_schema/0` (its only
  prior definition) so `StockSage.SettingsFragment` -- the pack `FragmentOwner`
  -- can derive from one source instead of a second literal copy, which is
  exactly how the two would drift. None of these keys match
  `AllbertAssist.Settings.Schema.sensitive_key?/1` (no `secret`, `token`,
  `password`, `api`, `key`, `private`, or `credential` segment), and none were
  ever declared non-writable, so every row stays `writable?: true,
  sensitive?: false` -- unlike the research fragment, which has both read-only
  and writable rows.
  """

  @doc "Return the StockSage settings schema fragment."
  def schema do
    [
      schema("stocksage.web.enabled", :boolean, true,
        description: "Master switch for the StockSage LiveView app surfaces."
      ),
      schema("stocksage.web.progress_stream_enabled", :boolean, true,
        description: "Enable live progress streaming on StockSage analysis detail surfaces."
      ),
      schema("stocksage.import.default_user", :string, "local",
        description: "Default local user id for StockSage import tasks."
      ),
      schema("stocksage.import.batch_size", :positive_integer, 500,
        description: "Maximum rows per insert batch during StockSage import."
      ),
      schema("stocksage.import.unknown_tables_as_warnings", :boolean, true,
        description: "Treat unknown legacy StockSage tables as warnings."
      ),
      schema("stocksage.list.max_results", :positive_integer, 50,
        description: "Maximum rows returned by StockSage list operations."
      ),
      schema("stocksage.queue.default_priority", :enum, "normal",
        allowed_values: ["low", "normal", "high"],
        description: "Default priority for new StockSage queue entries."
      ),
      schema("stocksage.outcomes.default_holding_period_days", :positive_integer, 30,
        description: "Default StockSage outcome holding period for manual resolution flows."
      ),
      schema("stocksage.outcomes.resolver_cadence", :enum, "manual",
        allowed_values: ["manual", "daily", "weekly"],
        description: "Operator cadence hint for StockSage outcome resolution."
      ),
      schema("stocksage.outcomes.neutral_return_threshold_pct", :bounded_float, 0.5,
        min: 0.0,
        max: 10.0,
        description: "Absolute return percentage treated as neutral during outcome resolution."
      ),
      schema("stocksage.reflections.enabled", :boolean, true,
        description: "Enable StockSage-local outcome reflection generation."
      ),
      schema("stocksage.reflections.max_chars", :bounded_integer, 1_200,
        min: 200,
        max: 4_000,
        description: "Maximum characters retained for a StockSage-local reflection."
      ),
      schema("stocksage.bridge_enabled", :boolean, true,
        description: "When false, the StockSage Python bridge does not open a Port."
      ),
      schema("stocksage.python_path", :string, "python3",
        description: "Path or name of the Python 3 interpreter the bridge spawns."
      ),
      schema("stocksage.bridge_timeout_ms", :positive_integer, 300_000,
        description: "Per-request timeout for StockSage bridge analyses (milliseconds)."
      ),
      schema("stocksage.bridge_max_output_bytes", :positive_integer, 1_048_576,
        description: "Maximum bridge response body retained before truncation (bytes)."
      ),
      schema("stocksage.analysis_engine", :enum, "tradingagents",
        allowed_values: ["tradingagents"],
        description: "Default analysis engine for StockSage RunAnalysis."
      ),
      schema("stocksage.native_engine_enabled", :boolean, true,
        description: "Master switch for the StockSage native agent engine."
      ),
      schema("stocksage.native_model_profile", :string, "fast",
        description: "Global model profile for StockSage native specialist agents."
      ),
      schema("stocksage.native_llm_enabled", :boolean, true,
        description:
          "Enable Jido.AI provider-backed generation for non-quality StockSage native specialist agents."
      ),
      schema("stocksage.native_model_profile_market_context", :string_or_nil, nil,
        description: "Model profile override for the market context specialist."
      ),
      schema("stocksage.native_model_profile_news_sentiment", :string_or_nil, nil,
        description: "Model profile override for the news sentiment specialist."
      ),
      schema("stocksage.native_model_profile_fundamentals", :string_or_nil, nil,
        description: "Model profile override for the fundamentals specialist."
      ),
      schema("stocksage.native_model_profile_bull_thesis", :string_or_nil, nil,
        description: "Model profile override for the bull thesis specialist."
      ),
      schema("stocksage.native_model_profile_bear_thesis", :string_or_nil, nil,
        description: "Model profile override for the bear thesis specialist."
      ),
      schema("stocksage.native_model_profile_risk_aggressive", :string, "slow",
        description: "Model profile override for the aggressive risk specialist."
      ),
      schema("stocksage.native_model_profile_risk_conservative", :string, "slow",
        description: "Model profile override for the conservative risk specialist."
      ),
      schema("stocksage.native_model_profile_risk_neutral", :string, "slow",
        description: "Model profile override for the neutral risk specialist."
      ),
      schema("stocksage.native_model_profile_research_manager", :string, "slow",
        description: "Model profile override for the research manager specialist."
      ),
      schema("stocksage.native_model_profile_trader_plan", :string, "slow",
        description: "Model profile override for the trader-plan specialist."
      ),
      schema("stocksage.native_model_profile_decision_synthesizer", :string, "slow",
        description: "Model profile override for the decision synthesizer specialist."
      ),
      schema("stocksage.native_agent_timeout_ms", :positive_integer, 180_000,
        description: "Per-specialist timeout for StockSage native agent dispatch (milliseconds)."
      ),
      schema("stocksage.native_max_debate_rounds", :bounded_integer, 2,
        min: 1,
        max: 5,
        description: "Maximum bull/bear debate rounds per native analysis."
      ),
      schema("stocksage.native_max_risk_rounds", :bounded_integer, 1,
        min: 1,
        max: 3,
        description: "Maximum risk debate rounds per native analysis."
      ),
      schema("stocksage.native_evidence_mode", :enum, "live",
        allowed_values: ["live", "fixture", "compare"],
        description: "Evidence posture for StockSage native evidence actions."
      ),
      schema("stocksage.native_parity_variance", :bounded_float, 0.25,
        min: 0.0,
        max: 1.0,
        description: "Confidence variance threshold for native/python parity checks."
      ),
      schema("stocksage.python_comparison_enabled", :boolean, true,
        description: "Allow explicit Python comparison and parity runs."
      )
    ]
  end

  defp schema(key, type, default, opts) do
    %{
      key: key,
      type: type,
      default: default,
      writable?: Keyword.get(opts, :writable?, true),
      sensitive?: Keyword.get(opts, :sensitive?, false),
      description: Keyword.fetch!(opts, :description)
    }
    |> maybe_put(:allowed_values, Keyword.get(opts, :allowed_values))
    |> maybe_put(:min, Keyword.get(opts, :min))
    |> maybe_put(:max, Keyword.get(opts, :max))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
