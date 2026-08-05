defmodule StockSage.IntentDescriptorsTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

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

  test "every declared StockSage operator phrase is actionable descriptor evidence" do
    descriptors = normalized_descriptors()

    for descriptor <- descriptors,
        phrase <- descriptor.examples ++ descriptor.synonyms do
      assert Descriptor.selection_evidence(descriptor, phrase).satisfied?,
             "#{descriptor.id} does not recognize its declared operator phrase: #{inspect(phrase)}"
    end
  end

  test "list-analysis operator variants stay explicit without treating supplied text as authority" do
    list_analyses =
      normalized_descriptors()
      |> Map.new(&{&1.action_name, &1})
      |> Map.fetch!("list_analyses")

    for prompt <- [
          "list my analyses",
          "list my recent analyses",
          "Please list my analyses"
        ] do
      assert Descriptor.selection_evidence(list_analyses, prompt).satisfied?, prompt
    end

    for prompt <- [
          ~s(Summarize this supplied sentence: "list my analyses"),
          ~s("list my recent analyses"),
          "Explain the phrase list my analyses"
        ] do
      refute Descriptor.selection_evidence(list_analyses, prompt).satisfied?, prompt
    end
  end

  defp normalized_descriptors do
    StockSage.App.intent_descriptors()
    |> Descriptor.normalize_many(app_id: :stocksage)
    |> Map.fetch!(:descriptors)
  end
end
