defmodule Mix.Tasks.Allbert.DelegateStockSageTest do
  use StockSage.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Allbert.Delegate, as: DelegateTask

  setup do
    previous_halt = Application.get_env(:allbert_assist, Mix.Tasks.Allbert.Delegate)

    Application.put_env(:allbert_assist, Mix.Tasks.Allbert.Delegate,
      halt_fun: fn code -> throw({:halt, code}) end
    )

    on_exit(fn ->
      Mix.Task.reenable("allbert.delegate")

      if previous_halt do
        Application.put_env(:allbert_assist, Mix.Tasks.Allbert.Delegate, previous_halt)
      else
        Application.delete_env(:allbert_assist, Mix.Tasks.Allbert.Delegate)
      end
    end)
  end

  test "delegates to a StockSage specialist with fixture evidence" do
    output =
      capture_io(fn ->
        assert :ok =
                 DelegateTask.run([
                   "stocksage.market_context",
                   ~s({"ticker":"AAPL","analysis_date":"2026-05-15","evidence_mode":"fixture","fixture":true,"user_id":"alice"}),
                   "--user",
                   "alice"
                 ])
      end)

    assert output =~ "Allbert delegate stocksage.market_context"
    assert output =~ "Status: completed"
    assert output =~ "Market context prepared for AAPL"
    assert output =~ "stocksage_fetch_market_data"
  end
end
