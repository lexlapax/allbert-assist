defmodule AllbertAssist.Objectives.ProposerTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Objectives.Proposer

  defmodule HybridFixture do
    @behaviour AllbertAssist.Objectives.ProposerBehaviour

    @impl true
    def propose(_intent_decision, %{proposer_hint: {:allbert, %{"cursor" => 1}}}) do
      {:ok, [step("MSFT")], :done}
    end

    def propose(_intent_decision, _context) do
      {:ok, [step("AAPL")], {:more, {:allbert, %{"cursor" => 1}}}}
    end

    defp step(ticker) do
      %{
        kind: "action",
        stage: "propose_steps",
        candidate_action: "StockSage.Actions.RunAnalysis",
        action_params: %{"ticker" => ticker}
      }
    end
  end

  test "registers and dispatches a bounded hybrid proposer" do
    on_exit(fn -> Proposer.unregister_app_proposer(:allbert) end)

    assert :ok = Proposer.register_app_proposer(:allbert, HybridFixture)

    assert {:ok, [first], {:more, {:allbert, %{"cursor" => 1}}}} =
             Proposer.propose(%{text: "analyze AAPL"}, %{active_app: :allbert})

    assert first.action_params == %{"ticker" => "AAPL"}

    assert {:ok, [second], :done} =
             Proposer.propose(%{text: "continue"}, %{
               active_app: :allbert,
               proposer_hint: {:allbert, %{"cursor" => 1}}
             })

    assert second.action_params == %{"ticker" => "MSFT"}
  end

  test "normalizes durable hints through app registry" do
    assert {:ok, {:allbert, %{"cursor" => 1}}} =
             Proposer.normalize_hint(%{"app_id" => "allbert", "state" => %{"cursor" => 1}})

    assert {:ok, %{"app_id" => "allbert", "state" => %{"cursor" => 1}}} =
             Proposer.hint_to_map({:allbert, %{"cursor" => 1}})
  end
end
