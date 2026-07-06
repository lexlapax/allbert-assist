defmodule StockSage.Plugin do
  @moduledoc """
  StockSage plugin entrypoint.

  The plugin contributes contract data only. Registration does not grant
  permissions, start analysis execution, or load code dynamically.
  """

  use AllbertAssist.Plugin

  @impl true
  def plugin_id, do: "stocksage"

  @impl true
  def display_name, do: "StockSage"

  @impl true
  def version, do: "0.35.0"

  @impl true
  def validate(_opts), do: :ok

  @impl true
  def apps, do: [StockSage.App]

  @impl true
  def actions do
    [
      StockSage.Actions.ListAnalyses,
      StockSage.Actions.ShowAnalysis,
      StockSage.Actions.GetTrends,
      StockSage.Actions.ResolveOutcomes,
      StockSage.Actions.GenerateReflection,
      StockSage.Actions.QueueAnalysis,
      StockSage.Actions.ListQueue,
      StockSage.Actions.ImportSqlite,
      StockSage.Actions.RunAnalysis,
      StockSage.Actions.Agents.ListAgents,
      StockSage.Actions.Agents.ShowAgent,
      StockSage.Actions.Evidence.FetchMarketData,
      StockSage.Actions.Evidence.FetchNews,
      StockSage.Actions.Evidence.FetchSentiment,
      StockSage.Actions.Evidence.FetchFundamentals,
      StockSage.Actions.Evidence.FetchFinancials
    ]
  end

  @impl true
  def skill_paths do
    # v0.62 M1: release-safe (see AllbertAssist.Plugin.Paths).
    [
      AllbertAssist.Plugin.Paths.plugin_path("stocksage", "skills") ||
        Path.expand("../../skills", __DIR__)
    ]
  end

  @impl true
  def settings_schema do
    [
      %{
        key: "stocksage.web.enabled",
        type: :boolean,
        default: true,
        description: "Master switch for the StockSage LiveView app surfaces."
      },
      %{
        key: "stocksage.web.progress_stream_enabled",
        type: :boolean,
        default: true,
        description: "Enable live progress streaming on StockSage analysis detail surfaces."
      },
      %{
        key: "stocksage.import.default_user",
        type: :string,
        default: "local",
        description: "Default local user id for StockSage import tasks."
      },
      %{
        key: "stocksage.import.batch_size",
        type: :positive_integer,
        default: 500,
        description: "Maximum rows per insert batch during StockSage import."
      },
      %{
        key: "stocksage.import.unknown_tables_as_warnings",
        type: :boolean,
        default: true,
        description: "Treat unknown legacy StockSage tables as warnings."
      },
      %{
        key: "stocksage.list.max_results",
        type: :positive_integer,
        default: 50,
        description: "Maximum rows returned by StockSage list operations."
      },
      %{
        key: "stocksage.queue.default_priority",
        type: :enum,
        default: "normal",
        allowed_values: ["low", "normal", "high"],
        description: "Default priority for new StockSage queue entries."
      },
      %{
        key: "stocksage.outcomes.default_holding_period_days",
        type: :positive_integer,
        default: 30,
        description: "Default StockSage outcome holding period for manual resolution flows."
      },
      %{
        key: "stocksage.outcomes.resolver_cadence",
        type: :enum,
        default: "manual",
        allowed_values: ["manual", "daily", "weekly"],
        description: "Operator cadence hint for StockSage outcome resolution."
      },
      %{
        key: "stocksage.outcomes.neutral_return_threshold_pct",
        type: :bounded_float,
        default: 0.5,
        min: 0.0,
        max: 10.0,
        description: "Absolute return percentage treated as neutral during outcome resolution."
      },
      %{
        key: "stocksage.reflections.enabled",
        type: :boolean,
        default: true,
        description: "Enable StockSage-local outcome reflection generation."
      },
      %{
        key: "stocksage.reflections.max_chars",
        type: :bounded_integer,
        default: 1_200,
        min: 200,
        max: 4_000,
        description: "Maximum characters retained for a StockSage-local reflection."
      },
      %{
        key: "stocksage.bridge_enabled",
        type: :boolean,
        default: true,
        description: "When false, the StockSage Python bridge does not open a Port."
      },
      %{
        key: "stocksage.python_path",
        type: :string,
        default: "python3",
        description: "Path or name of the Python 3 interpreter the bridge spawns."
      },
      %{
        key: "stocksage.bridge_timeout_ms",
        type: :positive_integer,
        default: 300_000,
        description: "Per-request timeout for StockSage bridge analyses (milliseconds)."
      },
      %{
        key: "stocksage.bridge_max_output_bytes",
        type: :positive_integer,
        default: 1_048_576,
        description: "Maximum bridge response body retained before truncation (bytes)."
      },
      %{
        key: "stocksage.analysis_engine",
        type: :enum,
        default: "tradingagents",
        allowed_values: ["tradingagents"],
        description: "Default analysis engine for StockSage RunAnalysis."
      },
      %{
        key: "stocksage.native_engine_enabled",
        type: :boolean,
        default: true,
        description: "Master switch for the StockSage native agent engine."
      },
      %{
        key: "stocksage.native_model_profile",
        type: :string,
        default: "fast",
        description: "Global model profile for StockSage native specialist agents."
      },
      %{
        key: "stocksage.native_llm_enabled",
        type: :boolean,
        default: true,
        description:
          "Enable Jido.AI provider-backed generation for non-quality StockSage native specialist agents."
      },
      %{
        key: "stocksage.native_model_profile_market_context",
        type: :string_or_nil,
        default: nil,
        description: "Model profile override for the market context specialist."
      },
      %{
        key: "stocksage.native_model_profile_news_sentiment",
        type: :string_or_nil,
        default: nil,
        description: "Model profile override for the news sentiment specialist."
      },
      %{
        key: "stocksage.native_model_profile_fundamentals",
        type: :string_or_nil,
        default: nil,
        description: "Model profile override for the fundamentals specialist."
      },
      %{
        key: "stocksage.native_model_profile_bull_thesis",
        type: :string_or_nil,
        default: nil,
        description: "Model profile override for the bull thesis specialist."
      },
      %{
        key: "stocksage.native_model_profile_bear_thesis",
        type: :string_or_nil,
        default: nil,
        description: "Model profile override for the bear thesis specialist."
      },
      %{
        key: "stocksage.native_model_profile_risk_aggressive",
        type: :string,
        default: "slow",
        description: "Model profile override for the aggressive risk specialist."
      },
      %{
        key: "stocksage.native_model_profile_risk_conservative",
        type: :string,
        default: "slow",
        description: "Model profile override for the conservative risk specialist."
      },
      %{
        key: "stocksage.native_model_profile_risk_neutral",
        type: :string,
        default: "slow",
        description: "Model profile override for the neutral risk specialist."
      },
      %{
        key: "stocksage.native_model_profile_research_manager",
        type: :string,
        default: "slow",
        description: "Model profile override for the research manager specialist."
      },
      %{
        key: "stocksage.native_model_profile_trader_plan",
        type: :string,
        default: "slow",
        description: "Model profile override for the trader-plan specialist."
      },
      %{
        key: "stocksage.native_model_profile_decision_synthesizer",
        type: :string,
        default: "slow",
        description: "Model profile override for the decision synthesizer specialist."
      },
      %{
        key: "stocksage.native_agent_timeout_ms",
        type: :positive_integer,
        default: 180_000,
        description: "Per-specialist timeout for StockSage native agent dispatch (milliseconds)."
      },
      %{
        key: "stocksage.native_max_debate_rounds",
        type: :bounded_integer,
        default: 2,
        min: 1,
        max: 5,
        description: "Maximum bull/bear debate rounds per native analysis."
      },
      %{
        key: "stocksage.native_max_risk_rounds",
        type: :bounded_integer,
        default: 1,
        min: 1,
        max: 3,
        description: "Maximum risk debate rounds per native analysis."
      },
      %{
        key: "stocksage.native_evidence_mode",
        type: :enum,
        default: "live",
        allowed_values: ["live", "fixture", "compare"],
        description: "Evidence posture for StockSage native evidence actions."
      },
      %{
        key: "stocksage.native_parity_variance",
        type: :bounded_float,
        default: 0.25,
        min: 0.0,
        max: 1.0,
        description: "Confidence variance threshold for native/python parity checks."
      },
      %{
        key: "stocksage.python_comparison_enabled",
        type: :boolean,
        default: true,
        description: "Allow explicit Python comparison and parity runs."
      }
    ]
  end

  @impl true
  # Return the supervisor's auto-generated child_spec map rather than the
  # `{module, args}` shorthand. The shorthand works at runtime (the
  # supervisor expands it) but mismatches `AllbertAssist.Plugin`'s
  # `child_spec/1` callback typespec, which expects a Supervisor.child_spec
  # map or `:ignore`. Dialyzer flagged the tuple form; this delegates to
  # `StockSage.Supervisor.child_spec/1` (auto-generated by `use Supervisor`)
  # so the returned value satisfies the typespec.
  def child_spec(opts), do: StockSage.Supervisor.child_spec(opts)
end
