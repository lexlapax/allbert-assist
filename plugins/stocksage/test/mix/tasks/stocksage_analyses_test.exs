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

  test "fails when user and operator differ" do
    assert_raise Mix.Error, ~r/--user alice differs from --operator bob/, fn ->
      capture_io(fn ->
        AnalysesTask.run(["list", "--user", "alice", "--operator", "bob"])
      end)
    end
  end
end
