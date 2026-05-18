defmodule StockSage.Evidence do
  @moduledoc """
  Evidence loading and live-request helpers for StockSage native agents.

  Fixture mode reads shipped synthetic data and never performs network I/O.
  Live mode builds requests through Allbert's external request posture and
  only executes when Security Central and external service settings allow it.
  """

  alias AllbertAssist.External.{HttpClient, RequestSpec}
  alias AllbertAssist.Signals, as: AllbertSignals
  alias AllbertAssist.Settings
  alias StockSage.Actions

  @fixture_date "2026-05-15"
  @body_excerpt_bytes 3_500
  @string_bytes 1_200
  @map_entries 32
  @list_entries 8
  @market_data_max_response_bytes 120_000
  @news_max_response_bytes 80_000
  @sentiment_max_response_bytes 80_000
  @fundamentals_max_response_bytes 120_000
  @financials_max_response_bytes 250_000
  @sec_user_agent "allbert-assist local operator research"
  @sec_max_response_bytes 250_000

  @sec_ciks %{
    "AAPL" => "0000320193",
    "FMCC" => "0001026214",
    "FNMA" => "0000310522",
    "GOOG" => "0001652044",
    "GOOGL" => "0001652044",
    "MSFT" => "0000789019",
    "NVDA" => "0001045810",
    "PLTR" => "0001321655"
  }

  @sec_fundamental_concepts [
    revenue: {"us-gaap", "RevenueFromContractWithCustomerExcludingAssessedTax", "USD"},
    revenue_legacy: {"us-gaap", "Revenues", "USD"},
    net_income: {"us-gaap", "NetIncomeLoss", "USD"},
    diluted_eps: {"us-gaap", "EarningsPerShareDiluted", "USD/shares"},
    diluted_shares: {"us-gaap", "WeightedAverageNumberOfDilutedSharesOutstanding", "shares"}
  ]

  @sec_financial_concepts [
    assets: {"us-gaap", "Assets", "USD"},
    liabilities: {"us-gaap", "Liabilities", "USD"},
    stockholders_equity: {"us-gaap", "StockholdersEquity", "USD"},
    cash: {"us-gaap", "CashAndCashEquivalentsAtCarryingValue", "USD"},
    operating_cash_flow: {"us-gaap", "NetCashProvidedByUsedInOperatingActivities", "USD"},
    capex: {"us-gaap", "PaymentsToAcquirePropertyPlantAndEquipment", "USD"}
  ]

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

  @doc """
  Return a bounded, redacted evidence shape suitable for native specialist
  prompts.

  This is deliberately richer than action trace metadata. Specialist agents
  need the actual bounded data content to reason, while traces and action
  summaries can stay compact.
  """
  @spec prompt_summary(map()) :: map()
  def prompt_summary(evidence) when is_map(evidence) do
    evidence
    |> common_prompt_summary()
    |> Map.merge(prompt_payload(evidence))
    |> AllbertSignals.redact()
  end

  def prompt_summary(other), do: %{raw: bounded_string(inspect(other))}

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

  defp live(kind, ticker, analysis_date, params) when kind in [:fundamentals, :financials] do
    sec = sec_company_concepts(kind, ticker, analysis_date, params)
    http = live_http(kind, ticker, analysis_date, params)

    case {sec, http} do
      {{:ok, sec_evidence}, {:ok, http_evidence}} ->
        {:ok, combined_fundamentals(kind, ticker, analysis_date, sec_evidence, http_evidence)}

      {{:ok, sec_evidence}, {:error, _reason}} ->
        {:ok, sec_evidence}

      {{:error, _reason}, {:ok, http_evidence}} ->
        {:ok, http_evidence}

      {{:error, :unsupported_sec_ticker}, {:error, http_reason}} ->
        {:error, http_reason}

      {{:error, sec_reason}, {:error, _http_reason}} ->
        {:error, sec_reason}
    end
  end

  defp live(kind, ticker, analysis_date, params) do
    live_http(kind, ticker, analysis_date, params)
  end

  defp live_http(kind, ticker, analysis_date, params) do
    with {:ok, url} <- live_url(kind, ticker, params),
         {:ok, spec} <-
           RequestSpec.normalize(%{
             method: "GET",
             url: url,
             profile: Actions.field(params, :external_profile) || "default",
             max_response_bytes:
               Actions.field(params, :max_response_bytes) || default_max_response_bytes(kind),
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

  defp sec_company_concepts(kind, ticker, analysis_date, params) do
    with {:ok, cik} <- sec_cik(ticker) do
      concepts =
        if kind == :fundamentals, do: @sec_fundamental_concepts, else: @sec_financial_concepts

      metrics =
        concepts
        |> Enum.map(fn {name, {taxonomy, concept, unit}} ->
          {name, sec_concept(cik, taxonomy, concept, unit, params)}
        end)
        |> Map.new()

      usable? =
        Enum.any?(metrics, fn {_name, value} ->
          is_map(value) and Map.get(value, :facts, []) != []
        end)

      if usable? do
        {:ok,
         %{
           kind: kind,
           mode: "live",
           source: "sec_companyconcept",
           provider: "sec",
           ticker: ticker,
           analysis_date: analysis_date,
           payload: %{
             provider: "sec_companyconcept",
             cik: cik,
             entity_hint: ticker,
             metrics: metrics
           }
         }}
      else
        {:error, {:sec_companyconcept_unavailable, metrics}}
      end
    end
  end

  defp sec_cik(ticker) do
    case Map.fetch(@sec_ciks, String.upcase(ticker)) do
      {:ok, cik} -> {:ok, cik}
      :error -> {:error, :unsupported_sec_ticker}
    end
  end

  defp combined_fundamentals(kind, ticker, analysis_date, sec_evidence, http_evidence) do
    %{
      kind: kind,
      mode: "live",
      source: "sec_plus_external_http",
      provider: "sec+yahoo_finance",
      ticker: ticker,
      analysis_date: analysis_date,
      payload: %{
        sec_companyconcept: Map.get(sec_evidence, :payload),
        quote_summary: prompt_summary(http_evidence)
      }
    }
  end

  defp sec_concept(cik, taxonomy, concept, unit, params) do
    url = "https://data.sec.gov/api/xbrl/companyconcept/CIK#{cik}/#{taxonomy}/#{concept}.json"

    with {:ok, spec} <-
           RequestSpec.normalize(%{
             method: "GET",
             url: url,
             headers: [{"user-agent", @sec_user_agent}],
             profile: Actions.field(params, :external_profile) || "default",
             max_response_bytes:
               Actions.field(params, :max_response_bytes) || @sec_max_response_bytes,
             source_text: "stocksage sec #{concept} #{cik}"
           }),
         {:ok, result} <- HttpClient.request(spec),
         {:ok, decoded} <- Jason.decode(Actions.field(result, :body_preview, "")) do
      %{
        taxonomy: taxonomy,
        concept: concept,
        label: Map.get(decoded, "label"),
        description: bounded_string(Map.get(decoded, "description", ""), 500),
        unit: unit,
        facts: latest_facts(decoded, unit),
        http_status: Actions.field(result, :http_status),
        truncated?: Actions.field(result, :truncated?)
      }
      |> drop_nil_values()
    else
      {:error, %RequestSpec{} = spec} ->
        %{concept: concept, error: :resource_access_denied, request: RequestSpec.summary(spec)}

      {:error, %Jason.DecodeError{} = error} ->
        %{concept: concept, error: {:decode_failed, Exception.message(error)}}
    end
  end

  defp latest_facts(decoded, preferred_unit) do
    units = Map.get(decoded, "units", %{})

    values =
      Map.get(units, preferred_unit) ||
        units |> Map.values() |> List.first() ||
        []

    values
    |> Enum.filter(fn fact ->
      is_map(fact) and is_number(Map.get(fact, "val")) and
        Map.get(fact, "form") in ["10-K", "10-Q"]
    end)
    |> Enum.sort_by(fn fact ->
      {Map.get(fact, "filed", ""), Map.get(fact, "end", "")}
    end)
    |> Enum.reverse()
    |> Enum.take(6)
    |> Enum.map(fn fact ->
      fact
      |> Map.take(["end", "fy", "fp", "form", "filed", "val", "frame"])
      |> compact_value()
    end)
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

  defp common_prompt_summary(evidence) do
    %{
      kind: Actions.field(evidence, :kind),
      mode: Actions.field(evidence, :mode),
      source: Actions.field(evidence, :source),
      ticker: Actions.field(evidence, :ticker),
      analysis_date: Actions.field(evidence, :analysis_date)
    }
    |> drop_nil_values()
  end

  defp prompt_payload(%{payload: payload}) do
    %{payload: compact_value(payload)}
  end

  defp prompt_payload(%{result: result} = evidence) when is_map(result) do
    body = Actions.field(result, :body_preview, "")
    decoded = decode_json(body)
    kind = Actions.field(evidence, :kind)
    parsed = parsed_summary(kind, decoded)

    %{
      http_status: Actions.field(result, :http_status),
      response_body_bytes: Actions.field(result, :response_body_bytes),
      truncated?: Actions.field(result, :truncated?),
      parsed: parsed,
      body_excerpt: maybe_body_excerpt(parsed, body)
    }
    |> drop_nil_values()
  end

  defp prompt_payload(%{fixture: fixture, live: live}) do
    %{
      fixture: prompt_summary(fixture),
      live: prompt_summary(live)
    }
  end

  defp prompt_payload(_evidence), do: %{}

  defp parsed_summary(_kind, nil), do: nil

  defp parsed_summary(:market_data, %{"chart" => %{"result" => [result | _rest]}}) do
    quote = result |> get_in(["indicators", "quote"]) |> first_map()
    indicators = technical_indicators(quote)

    %{
      meta:
        result
        |> Map.get("meta", %{})
        |> Map.take([
          "symbol",
          "currency",
          "exchangeName",
          "instrumentType",
          "regularMarketPrice",
          "previousClose",
          "chartPreviousClose",
          "regularMarketDayHigh",
          "regularMarketDayLow",
          "regularMarketVolume",
          "fiftyTwoWeekHigh",
          "fiftyTwoWeekLow"
        ]),
      latest_quote: latest_quote(quote),
      indicators: indicators,
      timestamps_seen: result |> Map.get("timestamp", []) |> length()
    }
    |> drop_nil_values()
  end

  defp parsed_summary(:news, %{"news" => news}) when is_list(news) do
    %{
      articles:
        Enum.map(Enum.take(news, @list_entries), fn item ->
          item
          |> Map.take(["title", "publisher", "providerPublishTime", "link", "type"])
          |> compact_value()
        end)
    }
  end

  defp parsed_summary(:sentiment, %{"messages" => messages}) when is_list(messages) do
    %{
      messages:
        Enum.map(Enum.take(messages, @list_entries), fn item ->
          item
          |> Map.take(["body", "created_at", "source", "symbols"])
          |> compact_value()
        end)
    }
  end

  defp parsed_summary(_kind, decoded), do: compact_value(decoded)

  defp latest_quote(nil), do: nil

  defp latest_quote(quote) do
    %{
      open: latest_value(Map.get(quote, "open")),
      high: latest_value(Map.get(quote, "high")),
      low: latest_value(Map.get(quote, "low")),
      close: latest_value(Map.get(quote, "close")),
      volume: latest_value(Map.get(quote, "volume"))
    }
    |> drop_nil_values()
  end

  defp technical_indicators(nil), do: nil

  defp technical_indicators(quote) do
    closes = numeric_series(quote, "close")
    highs = numeric_series(quote, "high")
    lows = numeric_series(quote, "low")
    volumes = numeric_series(quote, "volume")
    latest_close = latest_value(closes)

    %{
      latest_close: latest_close,
      sma_10: rounded(sma(closes, 10)),
      sma_50: rounded(sma(closes, 50)),
      sma_200: rounded(sma(closes, 200)),
      ema_10: rounded(ema(closes, 10)),
      rsi_14: rounded(rsi(closes, 14)),
      macd: macd(closes),
      atr_14: rounded(atr(highs, lows, closes, 14)),
      latest_volume: latest_value(volumes),
      trend:
        trend_summary(%{
          latest_close: latest_close,
          sma_10: sma(closes, 10),
          sma_50: sma(closes, 50),
          sma_200: sma(closes, 200),
          ema_10: ema(closes, 10)
        }),
      sample_size: length(closes)
    }
    |> drop_nil_values()
  end

  defp numeric_series(quote, key) do
    quote
    |> Map.get(key, [])
    |> Enum.filter(&is_number/1)
  end

  defp sma(values, period) when length(values) >= period do
    values
    |> Enum.take(-period)
    |> average()
  end

  defp sma(_values, _period), do: nil

  defp ema(values, period) when length(values) >= period do
    multiplier = 2 / (period + 1)

    values
    |> Enum.reduce(nil, fn value, acc ->
      case acc do
        nil -> value
        prev -> value * multiplier + prev * (1 - multiplier)
      end
    end)
  end

  defp ema(_values, _period), do: nil

  defp rsi(values, period) when length(values) > period do
    values
    |> deltas()
    |> Enum.take(-period)
    |> then(fn recent ->
      gains =
        recent
        |> Enum.map(&max(&1, 0))
        |> average()

      losses =
        recent
        |> Enum.map(&abs(min(&1, 0)))
        |> average()

      cond do
        is_nil(gains) or is_nil(losses) -> nil
        losses == 0.0 -> 100.0
        true -> 100 - 100 / (1 + gains / losses)
      end
    end)
  end

  defp rsi(_values, _period), do: nil

  defp macd(values) when length(values) >= 35 do
    macd_series =
      26..length(values)
      |> Enum.map(fn count ->
        sample = Enum.take(values, count)
        ema(sample, 12) - ema(sample, 26)
      end)

    line = List.last(macd_series)
    signal = ema(macd_series, 9)

    %{
      line: rounded(line),
      signal: rounded(signal),
      histogram: rounded(if(line && signal, do: line - signal))
    }
    |> drop_nil_values()
  end

  defp macd(_values), do: nil

  defp atr(highs, lows, closes, period)
       when length(highs) > period and length(lows) > period and length(closes) > period do
    count = Enum.min([length(highs), length(lows), length(closes)])
    highs = Enum.take(highs, -count)
    lows = Enum.take(lows, -count)
    closes = Enum.take(closes, -count)

    1..(count - 1)
    |> Enum.map(fn index ->
      high = Enum.at(highs, index)
      low = Enum.at(lows, index)
      previous_close = Enum.at(closes, index - 1)

      Enum.max([
        high - low,
        abs(high - previous_close),
        abs(low - previous_close)
      ])
    end)
    |> Enum.take(-period)
    |> average()
  end

  defp atr(_highs, _lows, _closes, _period), do: nil

  defp trend_summary(%{latest_close: latest_close} = values) when is_number(latest_close) do
    %{
      above_sma_10?: above?(latest_close, values.sma_10),
      above_sma_50?: above?(latest_close, values.sma_50),
      above_sma_200?: above?(latest_close, values.sma_200),
      above_ema_10?: above?(latest_close, values.ema_10)
    }
    |> drop_nil_values()
  end

  defp trend_summary(_values), do: nil

  defp above?(_value, nil), do: nil
  defp above?(value, baseline), do: value > baseline

  defp deltas(values) do
    values
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [left, right] -> right - left end)
  end

  defp average([]), do: nil

  defp average(values) do
    Enum.sum(values) / length(values)
  end

  defp rounded(nil), do: nil
  defp rounded(value) when is_number(value), do: Float.round(value / 1, 4)

  defp latest_value(values) when is_list(values) do
    values
    |> Enum.reverse()
    |> Enum.find(&(not is_nil(&1)))
  end

  defp latest_value(_values), do: nil

  defp first_map([value | _rest]) when is_map(value), do: value
  defp first_map(_value), do: nil

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> nil
    end
  end

  defp decode_json(_value), do: nil

  defp maybe_body_excerpt(nil, body), do: bounded_string(body, @body_excerpt_bytes)
  defp maybe_body_excerpt(_parsed, _body), do: nil

  defp compact_value(value), do: compact_value(value, 0)

  defp compact_value(value, depth) when is_map(value) and depth < 5 do
    value
    |> Enum.take(@map_entries)
    |> Map.new(fn {key, nested} -> {key, compact_value(nested, depth + 1)} end)
  end

  defp compact_value(value, depth) when is_list(value) and depth < 5 do
    value
    |> Enum.take(@list_entries)
    |> Enum.map(&compact_value(&1, depth + 1))
  end

  defp compact_value(value, _depth) when is_binary(value), do: bounded_string(value)

  defp compact_value(value, _depth)
       when is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp compact_value(value, _depth) when is_atom(value), do: Atom.to_string(value)
  defp compact_value(value, _depth), do: bounded_string(inspect(value))

  defp bounded_string(value, limit \\ @string_bytes) when is_binary(value) do
    if byte_size(value) > limit do
      binary_part(value, 0, limit) <> "...[truncated]"
    else
      value
    end
  end

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp live_url(:market_data, ticker, _params),
    do:
      {:ok,
       "https://query1.finance.yahoo.com/v8/finance/chart/#{URI.encode(ticker)}?range=1y&interval=1d&includePrePost=false"}

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

  defp default_max_response_bytes(:market_data), do: @market_data_max_response_bytes
  defp default_max_response_bytes(:news), do: @news_max_response_bytes
  defp default_max_response_bytes(:sentiment), do: @sentiment_max_response_bytes
  defp default_max_response_bytes(:fundamentals), do: @fundamentals_max_response_bytes
  defp default_max_response_bytes(:financials), do: @financials_max_response_bytes

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
