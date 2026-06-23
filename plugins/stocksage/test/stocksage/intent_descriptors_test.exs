defmodule StockSage.IntentDescriptorsTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Intent.Descriptor

  test "StockSage descriptors declare and extract their package-owned ticker slots" do
    descriptors =
      StockSage.App.intent_descriptors()
      |> Descriptor.normalize_many(app_id: :stocksage)
      |> Map.fetch!(:descriptors)
      |> Map.new(&{&1.action_name, &1})

    run_analysis = Map.fetch!(descriptors, "run_analysis")
    assert run_analysis.required_slots == [:ticker]

    assert %{extracted_slots: %{ticker: "AAPL"}, missing_slots: []} =
             Descriptor.extract_slots(run_analysis, "analyze AAPL")

    queue_analysis = Map.fetch!(descriptors, "queue_analysis")
    assert queue_analysis.required_slots == [:symbol]

    assert %{extracted_slots: %{symbol: "MSFT"}, missing_slots: []} =
             Descriptor.extract_slots(queue_analysis, "queue analysis for MSFT")
  end
end
