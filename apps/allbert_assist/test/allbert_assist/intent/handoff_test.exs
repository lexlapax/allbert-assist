defmodule AllbertAssist.Intent.HandoffTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Intent.Handoff

  setup :setup_stocksage_registry

  defp setup_stocksage_registry(context), do: AllbertAssist.StockSageRegistryCase.setup(context)

  test "normalizes a handoff proposal without granting authority" do
    assert {:ok, handoff} =
             Handoff.new(%{
               kind: :app_handoff,
               app_id: :stocksage,
               action_name: "run_analysis",
               label: "Run StockSage analysis",
               source_text: "analyze CIEN",
               extracted_slots: %{ticker: "CIEN"},
               permission: :stocksage_analyze,
               confirmation: :required
             })

    assert handoff.surface_id =~ "intent_app_handoff_stocksage_run_analysis_"
    assert Handoff.message(handoff) =~ "StockSage"
    assert Handoff.message(handoff) =~ "ticker CIEN"

    assert %{
             kind: :app_handoff,
             app_id: :stocksage,
             action_name: "run_analysis",
             extracted_slots: %{"ticker" => "CIEN"},
             permission: :stocksage_analyze,
             confirmation: :required
           } = Handoff.to_map(handoff)
  end

  test "builds a missing-slot clarification message" do
    assert {:ok, handoff} =
             Handoff.new(%{
               kind: :clarify_intent,
               app_id: :stocksage,
               action_name: "run_analysis",
               label: "Run StockSage analysis",
               missing_slots: [:ticker]
             })

    assert Handoff.message(handoff) ==
             "Which ticker should StockSage use for Run StockSage analysis?"
  end

  test "carries an inert workspace destination for panel handoff proposals" do
    assert {:ok, handoff} =
             Handoff.new(%{
               kind: :app_handoff,
               app_id: :allbert,
               action_name: "open_calendar_panel",
               label: "Open Calendar agenda",
               source_text: "show me today's agenda",
               destination: "workspace:calendar"
             })

    assert Handoff.message(handoff) =~ "open Calendar"

    assert %{
             kind: :app_handoff,
             app_id: :allbert,
             action_name: "open_calendar_panel",
             destination: "workspace:calendar"
           } = Handoff.to_map(handoff)
  end
end
