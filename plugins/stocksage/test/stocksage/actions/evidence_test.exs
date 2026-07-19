defmodule StockSage.Actions.EvidenceTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings
  alias StockSage.Evidence

  setup do
    original = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "stocksage-evidence-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    PluginRegistry.register_module(StockSage.Plugin)

    on_exit(fn ->
      if original do
        Application.put_env(:allbert_assist, Settings, original)
      else
        Application.delete_env(:allbert_assist, Settings)
      end

      File.rm_rf!(root)
    end)

    :ok
  end

  test "fixture mode loads synthetic market evidence without external grants" do
    assert {:ok, response} =
             Runner.run(
               "stocksage_fetch_market_data",
               %{ticker: "AAPL", analysis_date: "2026-05-15", evidence_mode: "fixture"},
               %{
                 active_app: :stocksage,
                 request: %{
                   active_app: :stocksage,
                   channel: :test,
                   user_id: "alice",
                   operator_id: "alice"
                 }
               }
             )

    assert response.status == :completed
    assert response.evidence.kind == :market_data
    assert response.evidence.mode == "fixture"
    assert response.evidence.payload["license"] == "synthetic"
    assert hd(response.resource_access).mode == "fixture"

    summary = Evidence.prompt_summary(response.evidence)
    assert summary.payload["ticker"] == "AAPL"
    assert summary.payload["license"] == "synthetic"
  end

  test "live prompt summary includes bounded response content, not only fetch metadata" do
    closes = Enum.map(1..210, &(100.0 + &1 / 2))
    highs = Enum.map(closes, &(&1 + 1.0))
    lows = Enum.map(closes, &(&1 - 1.0))
    opens = Enum.map(closes, &(&1 - 0.5))
    volumes = Enum.map(1..210, &(1_000 + &1))

    body =
      Jason.encode!(%{
        "chart" => %{
          "result" => [
            %{
              "meta" => %{
                "symbol" => "AAPL",
                "regularMarketPrice" => 211.26,
                "previousClose" => 210.02,
                "currency" => "USD"
              },
              "timestamp" => Enum.to_list(1..210),
              "indicators" => %{
                "quote" => [
                  %{
                    "open" => opens,
                    "high" => highs,
                    "low" => lows,
                    "close" => closes,
                    "volume" => volumes
                  }
                ]
              }
            }
          ]
        }
      })

    summary =
      Evidence.prompt_summary(%{
        kind: :market_data,
        mode: "live",
        source: "external_http",
        ticker: "AAPL",
        analysis_date: "2026-05-15",
        result: %{
          http_status: 200,
          response_body_bytes: byte_size(body),
          body_preview: body,
          truncated?: false
        }
      })

    assert summary.http_status == 200
    assert get_in(summary, [:parsed, :meta, "regularMarketPrice"]) == 211.26
    assert get_in(summary, [:parsed, :latest_quote, :close]) == List.last(closes)
    assert get_in(summary, [:parsed, :indicators, :sma_50])
    assert get_in(summary, [:parsed, :indicators, :rsi_14])
    assert get_in(summary, [:parsed, :indicators, :trend, :above_sma_50?]) == true
    refute Map.has_key?(summary, :body_excerpt)
  end

  test "global evidence mode and per-call override are respected" do
    assert {:ok, _setting} =
             Settings.put("stocksage.native_evidence_mode", "fixture", %{audit?: false})

    assert Evidence.mode(%{}) == "fixture"
    assert Evidence.mode(%{evidence_mode: "live"}) == "live"
    assert Evidence.mode(%{fixture: true, evidence_mode: "live"}) == "fixture"
  end

  test "live evidence outside approved analysis requires confirmation" do
    assert {:ok, response} =
             Runner.run(
               "stocksage_fetch_news",
               %{ticker: "AAPL", analysis_date: "2026-05-15", evidence_mode: "live"},
               %{
                 active_app: :stocksage,
                 request: %{
                   active_app: :stocksage,
                   channel: :test,
                   user_id: "alice",
                   operator_id: "alice"
                 }
               }
             )

    assert response.status == :needs_confirmation
    assert response.error == :resource_access_required
    assert hd(response.resource_access).mode == "live"
  end

  test "all shipped synthetic fixtures decode for the smoke tickers and evidence kinds" do
    for kind <- [:market_data, :news, :sentiment, :fundamentals, :financials],
        ticker <- ~w[AAPL MSFT NVDA] do
      assert {:ok, evidence} =
               Evidence.fetch(kind, %{
                 ticker: ticker,
                 analysis_date: "2026-05-15",
                 evidence_mode: "fixture"
               })

      assert evidence.payload["ticker"] == ticker
      assert evidence.payload["license"] == "synthetic"
    end
  end
end
