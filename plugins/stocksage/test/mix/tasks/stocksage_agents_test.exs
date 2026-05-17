defmodule Mix.Tasks.Stocksage.AgentsTest do
  use StockSage.DataCase

  import ExUnit.CaptureIO

  alias Mix.Tasks.Stocksage.Agents, as: AgentsTask

  setup do
    on_exit(fn -> Mix.Task.reenable("stocksage.agents") end)
    :ok
  end

  test "lists native specialist agents" do
    output =
      capture_io(fn ->
        assert :ok = AgentsTask.run(["list", "--user", "alice"])
      end)

    assert output =~ "StockSage native agents"
    assert output =~ "stocksage.market_context"
    assert output =~ "prompt_version=v0.25.0"
  end

  test "shows one native specialist agent" do
    output =
      capture_io(fn ->
        assert :ok = AgentsTask.run(["show", "stocksage.market_context", "--user", "alice"])
      end)

    assert output =~ "StockSage native agent stocksage.market_context"
    assert output =~ "Role: market_context"
    assert output =~ "Prompt path:"
  end

  test "show reports unknown agent ids" do
    assert_raise Mix.Error, ~r/not found/, fn ->
      capture_io(fn ->
        AgentsTask.run(["show", "stocksage.nope", "--user", "alice"])
      end)
    end
  end

  test "smoke delegates through objective action boundary and fixture evidence" do
    output =
      capture_io(fn ->
        assert :ok =
                 AgentsTask.run([
                   "smoke",
                   "stocksage.market_context",
                   "--ticker",
                   "AAPL",
                   "--analysis-date",
                   "2026-05-15",
                   "--fixture",
                   "--user",
                   "alice"
                 ])
      end)

    assert output =~ "StockSage native agent smoke stocksage.market_context"
    assert output =~ "Evidence packets: 1"
    assert output =~ "stocksage_fetch_market_data"
    assert output =~ "mode=fixture"
  end
end
