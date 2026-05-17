defmodule Mix.Tasks.Stocksage.AnalysesTest do
  use StockSage.DataCase

  import ExUnit.CaptureIO

  alias Mix.Tasks.Stocksage.Analyses, as: AnalysesTask
  alias StockSage.Analyses

  setup do
    assert {:ok, analysis} =
             Analyses.create_analysis(%{
               user_id: "alice",
               symbol: "aapl",
               status: "completed",
               source: "manual",
               recommendation: "buy",
               score: "0.82",
               summary: String.duplicate("bounded ", 100)
             })

    assert {:ok, _detail} =
             Analyses.create_detail(%{
               user_id: "alice",
               analysis_id: analysis.id,
               section: "technical",
               content: "AAPL trend"
             })

    on_exit(fn -> Mix.Task.reenable("stocksage.analyses") end)
    {:ok, analysis: analysis}
  end

  test "lists bounded user-scoped rows", %{analysis: analysis} do
    output =
      capture_io(fn ->
        assert :ok = AnalysesTask.run(["list", "--user", "alice", "--symbol", "aapl"])
      end)

    assert output =~ "StockSage analyses for alice"
    assert output =~ analysis.id
    assert output =~ "AAPL"
    refute output =~ String.duplicate("bounded ", 100)
  end

  test "shows detail for matching user and hides cross-user ids", %{analysis: analysis} do
    output =
      capture_io(fn ->
        assert :ok = AnalysesTask.run(["show", analysis.id, "--user", "alice"])
      end)

    assert output =~ "StockSage analysis #{analysis.id}"
    assert output =~ "technical"

    Mix.Task.reenable("stocksage.analyses")

    assert_raise Mix.Error, ~r/not found/, fn ->
      capture_io(fn ->
        AnalysesTask.run(["show", analysis.id, "--user", "bob"])
      end)
    end
  end

  test "show surfaces detail payload.stub so operators can see stub-mode rows" do
    # v0.22 third-validation closeout (MED): the previous implementation
    # dropped `payload` in `ShowAnalysis.detail_summary/1`, so the CLI
    # show command could not reveal whether a detail row came from the
    # deterministic stub path or a real TradingAgents call. The plan
    # claimed `payload.stub` would be visible here; this test pins that.
    assert {:ok, analysis} =
             Analyses.create_analysis(%{
               user_id: "carol",
               symbol: "msft",
               status: "completed",
               source: "python_bridge",
               summary: "MSFT stub-mode trace fixture"
             })

    assert {:ok, _detail_stub} =
             Analyses.create_detail(%{
               user_id: "carol",
               analysis_id: analysis.id,
               section: "result",
               agent: "python_bridge",
               content: "stub-mode bounded payload",
               payload: %{"engine" => "tradingagents", "truncated" => false, "stub" => true}
             })

    output =
      capture_io(fn ->
        assert :ok = AnalysesTask.run(["show", analysis.id, "--user", "carol"])
      end)

    assert output =~ "stub=true",
           "expected `stub=true` in show output; got:\n#{output}"

    assert output =~ "engine=tradingagents",
           "expected `engine=tradingagents` in show output; got:\n#{output}"
  end

  test "show output for legacy detail rows without payload still works" do
    # Backward compatibility: detail rows persisted before v0.22 may not
    # have payload fields. The CLI must not crash and the bounded line
    # for legacy rows should match the pre-v0.22 shape (no `(...)`
    # meta block appended).
    assert {:ok, analysis} =
             Analyses.create_analysis(%{
               user_id: "dave",
               symbol: "nvda",
               status: "completed",
               source: "manual",
               summary: "Legacy row with no payload"
             })

    assert {:ok, _detail} =
             Analyses.create_detail(%{
               user_id: "dave",
               analysis_id: analysis.id,
               section: "legacy_section",
               content: "no payload here"
             })

    output =
      capture_io(fn ->
        assert :ok = AnalysesTask.run(["show", analysis.id, "--user", "dave"])
      end)

    assert output =~ "- legacy_section: no payload here"

    refute output =~ "stub=",
           "legacy rows should not synthesize a stub label when none was persisted"
  end

  test "fails when user and operator differ" do
    assert_raise Mix.Error, ~r/--user alice differs from --operator bob/, fn ->
      capture_io(fn ->
        AnalysesTask.run(["list", "--user", "alice", "--operator", "bob"])
      end)
    end
  end
end
