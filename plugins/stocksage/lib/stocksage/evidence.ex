defmodule StockSage.Evidence do
  @moduledoc """
  Evidence loading and live-request helpers for StockSage native agents.

  Fixture mode reads shipped synthetic data and never performs network I/O.
  Live mode builds requests through Allbert's external request posture and
  only executes when Security Central and external service settings allow it.
  """

  alias AllbertAssist.External.{HttpClient, RequestSpec}
  alias AllbertAssist.Settings
  alias StockSage.Actions

  @fixture_date "2026-05-15"

  @kind_metadata %{
    market_data: %{
      provider: "yahoo_finance",
      operation_class: :external_service_request,
      access_mode: :fetch,
      downstream_consumer: "stocksage_fetch_market_data"
    },
    news: %{
      provider: "yahoo_finance_news",
      operation_class: :external_service_request,
      access_mode: :fetch,
      downstream_consumer: "stocksage_fetch_news"
    },
    sentiment: %{
      provider: "stocktwits_reddit",
      operation_class: :external_service_request,
      access_mode: :fetch,
      downstream_consumer: "stocksage_fetch_sentiment"
    },
    fundamentals: %{
      provider: "yahoo_finance_alpha_vantage",
      operation_class: :external_service_request,
      access_mode: :fetch,
      downstream_consumer: "stocksage_fetch_fundamentals"
    },
    financials: %{
      provider: "yahoo_finance_alpha_vantage",
      operation_class: :external_service_request,
      access_mode: :fetch,
      downstream_consumer: "stocksage_fetch_financials"
    }
  }

  def fetch(kind, params) when is_atom(kind) and is_map(params) do
    mode = mode(params)
    ticker = ticker(params)
    analysis_date = analysis_date(params)

    case mode do
      "fixture" -> load_fixture(kind, ticker, analysis_date)
      "live" -> live(kind, ticker, analysis_date, params)
      "compare" -> compare(kind, ticker, analysis_date, params)
    end
  end

  @spec mode(map()) :: String.t()
  def mode(params) do
    cond do
      truthy?(Actions.field(params, :fixture)) ->
        "fixture"

      Actions.field(params, :evidence_mode) in ["live", "fixture", "compare"] ->
        Actions.field(params, :evidence_mode)

      true ->
        case Settings.get("stocksage.native_evidence_mode") do
          {:ok, value} when value in ["live", "fixture", "compare"] -> value
          _other -> "live"
        end
    end
  end

  @spec resource_access(atom(), map()) :: map()
  def resource_access(kind, params) do
    metadata = Map.fetch!(@kind_metadata, kind)

    %{
      kind: kind,
      permission: :stocksage_evidence_fetch,
      provider: metadata.provider,
      operation_class: metadata.operation_class,
      access_mode: metadata.access_mode,
      scope: :bounded_external_service,
      rate_limit: "operator-configured external_services profile",
      downstream_consumer: metadata.downstream_consumer,
      mode: mode(params),
      ticker: ticker(params),
      analysis_date: analysis_date(params)
    }
  end

  @spec fixture_path(atom(), String.t(), String.t()) :: Path.t()
  def fixture_path(kind, ticker, analysis_date) do
    Path.join([
      fixture_root(),
      Atom.to_string(kind),
      "#{String.upcase(ticker)}_#{analysis_date}.json"
    ])
  end

  @spec fixture_root() :: Path.t()
  def fixture_root do
    Path.expand("../../priv/fixtures/native_agents", __DIR__)
  end

  defp load_fixture(kind, ticker, analysis_date) do
    path = fixture_path(kind, ticker, analysis_date)

    with {:ok, body} <- File.read(path),
         {:ok, payload} <- Jason.decode(body) do
      {:ok,
       %{
         kind: kind,
         mode: "fixture",
         source: "synthetic_fixture",
         ticker: ticker,
         analysis_date: analysis_date,
         fixture_path: path,
         payload: payload
       }}
    else
      {:error, :enoent} ->
        {:error, {:fixture_not_found, path}}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:fixture_decode_failed, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp live(kind, ticker, analysis_date, params) do
    with {:ok, url} <- live_url(kind, ticker, params),
         {:ok, spec} <-
           RequestSpec.normalize(%{
             method: "GET",
             url: url,
             profile: Actions.field(params, :external_profile) || "default",
             max_response_bytes: Actions.field(params, :max_response_bytes) || 25_000,
             source_text: "stocksage #{kind} #{ticker}"
           }),
         {:ok, result} <- HttpClient.request(spec) do
      {:ok,
       %{
         kind: kind,
         mode: "live",
         source: "external_http",
         ticker: ticker,
         analysis_date: analysis_date,
         request: RequestSpec.summary(spec),
         result: result
       }}
    else
      {:error, %RequestSpec{} = spec} ->
        {:error, {:resource_access_denied, RequestSpec.summary(spec)}}
    end
  end

  defp compare(kind, ticker, analysis_date, params) do
    fixture = load_fixture(kind, ticker, analysis_date)
    live = live(kind, ticker, analysis_date, params)

    with {:ok, fixture_evidence} <- fixture do
      {:ok,
       %{
         kind: kind,
         mode: "compare",
         source: "fixture_plus_live",
         ticker: ticker,
         analysis_date: analysis_date,
         fixture: fixture_evidence,
         live: compare_live(live)
       }}
    end
  end

  defp compare_live({:ok, evidence}), do: evidence
  defp compare_live({:error, reason}), do: %{status: :error, reason: inspect(reason)}

  defp live_url(:market_data, ticker, _params),
    do: {:ok, "https://query1.finance.yahoo.com/v8/finance/chart/#{URI.encode(ticker)}"}

  defp live_url(:news, ticker, _params),
    do:
      {:ok,
       "https://query1.finance.yahoo.com/v1/finance/search?q=#{URI.encode(ticker)}&newsCount=5"}

  defp live_url(:sentiment, ticker, _params),
    do: {:ok, "https://api.stocktwits.com/api/2/streams/symbol/#{URI.encode(ticker)}.json"}

  defp live_url(:fundamentals, ticker, _params) do
    modules = "summaryProfile,price,defaultKeyStatistics"

    {:ok,
     "https://query1.finance.yahoo.com/v10/finance/quoteSummary/#{URI.encode(ticker)}?modules=#{modules}"}
  end

  defp live_url(:financials, ticker, _params) do
    modules = "financialData,balanceSheetHistory,cashflowStatementHistory,incomeStatementHistory"

    {:ok,
     "https://query1.finance.yahoo.com/v10/finance/quoteSummary/#{URI.encode(ticker)}?modules=#{modules}"}
  end

  defp ticker(params) do
    params
    |> Actions.field(:ticker, "UNKNOWN")
    |> to_string()
    |> String.trim()
    |> String.upcase()
  end

  defp analysis_date(params) do
    params
    |> Actions.field(:analysis_date, @fixture_date)
    |> to_string()
    |> String.trim()
    |> case do
      "" -> @fixture_date
      value -> value
    end
  end

  defp truthy?(value), do: value in [true, "true", "1", 1, true]
end
