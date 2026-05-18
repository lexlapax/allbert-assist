defmodule StockSage.Agents.NativeCoordinator.ParityRunTest do
  use StockSage.DataCase, async: false

  alias StockSage.Agents.NativeCoordinator.Commands.ParityRun

  test "rating agreement scores exact, adjacent, and distant ratings" do
    assert ParityRun.rating_agreement("Hold", "Hold") == 1.0
    assert ParityRun.rating_agreement("Hold", "Overweight") == 0.5
    assert ParityRun.rating_agreement("Sell", "Buy") == 0.0
  end

  test "parity diff passes within variance and fails outside variance" do
    native = {:ok, %{final_trade_decision: "Hold", confidence: 0.7}}
    python = {:ok, %{decision: "Overweight", confidence: 0.6}}

    pass = ParityRun.parity_diff(native, python, 0.25)
    assert pass["rating_agreement"] == 0.5
    assert pass["confidence_delta"] == 0.1
    assert pass["within_variance"] == true
    assert pass["parity_pass"] == true

    fail = ParityRun.parity_diff(native, python, 0.05)
    assert fail["within_variance"] == false
    assert fail["parity_pass"] == false
  end

  test "parity diff records one-sided failures without claiming pass" do
    diff = ParityRun.parity_diff({:error, :native_failed}, {:ok, %{decision: "Hold"}}, 0.25)

    assert diff["native_status"] == "error"
    assert diff["python_status"] == "ok"
    assert diff["native_error"] =~ "native_failed"
    assert diff["parity_pass"] == false
  end
end
