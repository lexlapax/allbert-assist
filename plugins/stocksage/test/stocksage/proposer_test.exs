defmodule StockSage.ProposerTest do
  use ExUnit.Case, async: true

  alias StockSage.Proposer

  test "single-ticker prompt returns one inert RunAnalysis step" do
    assert {:ok, [step], :done} =
             Proposer.propose(%{text: "analyze AAPL"}, %{user_id: "alice"})

    assert step.kind == "action"
    assert step.stage == "propose_steps"
    assert step.candidate_action == "StockSage.Actions.RunAnalysis"
    assert step.action_params.ticker == "AAPL"
    assert step.action_params.user_id == "alice"
  end

  test "two-ticker prompt uses the hybrid continuation contract" do
    assert {:ok, [first], {:more, {:stocksage, hint}}} =
             Proposer.propose(%{text: "analyze AAPL and compare to MSFT"}, %{user_id: "alice"})

    assert first.action_params.ticker == "AAPL"
    assert hint["remaining_tickers"] == ["MSFT"]

    assert {:ok, [second], :done} =
             Proposer.propose(%{text: "continue"}, %{
               user_id: "alice",
               proposer_hint: {:stocksage, Map.put(hint, "completed_steps", ["step_aapl"])}
             })

    assert second.action_params.ticker == "MSFT"
    assert second.parent_step_id == "step_aapl"
  end

  test "unknown prompts produce no executable steps" do
    assert {:no_steps, :no_tickers_recognized} =
             Proposer.propose(%{text: "explain the market"}, %{})
  end
end
