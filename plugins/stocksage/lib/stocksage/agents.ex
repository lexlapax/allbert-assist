defmodule StockSage.Agents do
  @moduledoc """
  Catalog and helpers for StockSage native financial specialist agents.

  v0.25 keeps these agents plugin-owned but runtime-callable through the
  shared Allbert objective delegate-agent boundary.
  """

  @prompt_version "v0.25.0"

  @specialists [
    %{
      id: "stocksage.market_context",
      module: StockSage.Agents.MarketContext,
      role: :market_context,
      prompt_file: "market_context.md",
      prompt_version: @prompt_version,
      type: :jido_ai,
      model_role: :market_context,
      default_model_profile: "fast",
      tool_modules: [StockSage.Actions.Evidence.FetchMarketData],
      tool_names: ["stocksage_fetch_market_data"]
    },
    %{
      id: "stocksage.news_sentiment",
      module: StockSage.Agents.NewsSentiment,
      role: :news_sentiment,
      prompt_file: "news_sentiment.md",
      prompt_version: @prompt_version,
      type: :jido_ai,
      model_role: :news_sentiment,
      default_model_profile: "fast",
      tool_modules: [
        StockSage.Actions.Evidence.FetchNews,
        StockSage.Actions.Evidence.FetchSentiment
      ],
      tool_names: ["stocksage_fetch_news", "stocksage_fetch_sentiment"]
    },
    %{
      id: "stocksage.fundamentals",
      module: StockSage.Agents.Fundamentals,
      role: :fundamentals,
      prompt_file: "fundamentals.md",
      prompt_version: @prompt_version,
      type: :jido_ai,
      model_role: :fundamentals,
      default_model_profile: "fast",
      tool_modules: [
        StockSage.Actions.Evidence.FetchMarketData,
        StockSage.Actions.Evidence.FetchFundamentals,
        StockSage.Actions.Evidence.FetchFinancials
      ],
      tool_names: [
        "stocksage_fetch_market_data",
        "stocksage_fetch_fundamentals",
        "stocksage_fetch_financials"
      ]
    },
    %{
      id: "stocksage.bull_thesis",
      module: StockSage.Agents.BullThesis,
      role: :bull_thesis,
      prompt_file: "bull_thesis.md",
      prompt_version: @prompt_version,
      type: :jido_ai,
      model_role: :bull_thesis,
      default_model_profile: "fast",
      tool_modules: [],
      tool_names: []
    },
    %{
      id: "stocksage.bear_thesis",
      module: StockSage.Agents.BearThesis,
      role: :bear_thesis,
      prompt_file: "bear_thesis.md",
      prompt_version: @prompt_version,
      type: :jido_ai,
      model_role: :bear_thesis,
      default_model_profile: "fast",
      tool_modules: [],
      tool_names: []
    },
    %{
      id: "stocksage.risk_aggressive",
      module: StockSage.Agents.RiskAggressive,
      role: :risk_aggressive,
      prompt_file: "risk_aggressive.md",
      prompt_version: @prompt_version,
      type: :jido_ai,
      model_role: :risk_aggressive,
      default_model_profile: "slow",
      tool_modules: [],
      tool_names: []
    },
    %{
      id: "stocksage.risk_conservative",
      module: StockSage.Agents.RiskConservative,
      role: :risk_conservative,
      prompt_file: "risk_conservative.md",
      prompt_version: @prompt_version,
      type: :jido_ai,
      model_role: :risk_conservative,
      default_model_profile: "slow",
      tool_modules: [],
      tool_names: []
    },
    %{
      id: "stocksage.risk_neutral",
      module: StockSage.Agents.RiskNeutral,
      role: :risk_neutral,
      prompt_file: "risk_neutral.md",
      prompt_version: @prompt_version,
      type: :jido_ai,
      model_role: :risk_neutral,
      default_model_profile: "slow",
      tool_modules: [],
      tool_names: []
    },
    %{
      id: "stocksage.research_manager",
      module: StockSage.Agents.ResearchManager,
      role: :research_manager,
      prompt_file: "research_manager.md",
      prompt_version: @prompt_version,
      type: :jido_ai,
      model_role: :research_manager,
      default_model_profile: "slow",
      tool_modules: [],
      tool_names: []
    },
    %{
      id: "stocksage.trader_plan",
      module: StockSage.Agents.TraderPlan,
      role: :trader_plan,
      prompt_file: "trader_plan.md",
      prompt_version: @prompt_version,
      type: :jido_ai,
      model_role: :trader_plan,
      default_model_profile: "slow",
      tool_modules: [],
      tool_names: []
    },
    %{
      id: "stocksage.decision_synthesizer",
      module: StockSage.Agents.DecisionSynthesizer,
      role: :decision_synthesizer,
      prompt_file: "decision_synthesizer.md",
      prompt_version: @prompt_version,
      type: :jido_ai,
      model_role: :decision_synthesizer,
      default_model_profile: "slow",
      tool_modules: [],
      tool_names: []
    },
    %{
      id: "stocksage.quality_gate",
      module: StockSage.Agents.QualityGate,
      role: :quality_gate,
      prompt_file: "quality_gate.md",
      prompt_version: @prompt_version,
      type: :jido,
      model_role: nil,
      default_model_profile: nil,
      tool_modules: [],
      tool_names: []
    }
  ]

  def specialists, do: @specialists

  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@specialists, & &1.id)

  @spec modules() :: [module()]
  def modules, do: Enum.map(@specialists, & &1.module)

  @spec spec(String.t() | atom()) :: {:ok, map()} | {:error, :not_found}
  def spec(id_or_role) do
    case Enum.find(@specialists, &matches_id_or_role?(&1, id_or_role)) do
      nil -> {:error, :not_found}
      spec -> {:ok, spec}
    end
  end

  @spec spec!(String.t() | atom()) :: map()
  def spec!(id_or_role) do
    case spec(id_or_role) do
      {:ok, spec} ->
        spec

      {:error, :not_found} ->
        raise ArgumentError, "unknown StockSage agent #{inspect(id_or_role)}"
    end
  end

  @spec prompt_root() :: Path.t()
  def prompt_root do
    # v0.62 M1: release-safe (see AllbertAssist.Plugin.Paths).
    AllbertAssist.Plugin.Paths.plugin_path("stocksage", ["priv", "prompts", "native_agents"]) ||
      Path.expand("../../priv/prompts/native_agents", __DIR__)
  end

  @spec prompt_path(map() | String.t()) :: Path.t()
  def prompt_path(%{prompt_file: prompt_file}), do: prompt_path(prompt_file)

  def prompt_path(prompt_file) when is_binary(prompt_file),
    do: Path.join(prompt_root(), prompt_file)

  @spec prompt_version() :: String.t()
  def prompt_version, do: @prompt_version

  defp matches_id_or_role?(spec, value) when is_atom(value), do: spec.role == value

  defp matches_id_or_role?(spec, value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.replace("-", "_")

    normalized in [spec.id, Atom.to_string(spec.role), "stocksage.#{spec.role}"]
  end

  defp matches_id_or_role?(_spec, _value), do: false
end
