defmodule AllbertAssist.Intent.DescriptorTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Intent.Descriptor

  setup do
    app_registered? = AppRegistry.known_app_id?(:stocksage)

    unless app_registered? do
      assert {:ok, :stocksage} = AppRegistry.register(StockSage.App)
    end

    on_exit(fn ->
      unless app_registered?, do: AppRegistry.unregister(:stocksage)
    end)

    :ok
  end

  test "normalizes inert descriptors for registered app actions" do
    assert {:ok, descriptor} =
             Descriptor.normalize(%{
               app_id: :stocksage,
               action_name: "run_analysis",
               label: "Run StockSage analysis",
               examples: ["analyze AAPL"],
               synonyms: ["analysis"],
               required_slots: ["ticker"],
               slot_extractors: %{"ticker" => "ticker_symbol"},
               handoff_required?: true
             })

    assert descriptor.id == "stocksage:run_analysis"
    assert descriptor.app_id == :stocksage
    assert descriptor.action_name == "run_analysis"
    assert descriptor.required_slots == [:ticker]
    assert descriptor.slot_extractors == %{ticker: :ticker_symbol}
    assert descriptor.capability.permission == :stocksage_analyze
    assert descriptor.capability.confirmation == :required
  end

  test "rejects descriptors for unknown or mismatched actions" do
    assert {:error, %{kind: :invalid_intent_descriptor, reason: reason}} =
             Descriptor.normalize(%{
               app_id: :stocksage,
               action_name: "direct_answer",
               label: "Bad descriptor",
               required_slots: []
             })

    assert match?({:action_app_mismatch, :stocksage, "direct_answer"}, reason)
  end

  test "extracts required slots conservatively" do
    assert {:ok, descriptor} =
             Descriptor.normalize(%{
               app_id: :stocksage,
               action_name: "run_analysis",
               label: "Run StockSage analysis",
               required_slots: [:ticker],
               slot_extractors: %{ticker: :ticker_symbol}
             })

    assert Descriptor.extract_slots(descriptor, "analyze CIEN") == %{
             extracted_slots: %{ticker: "CIEN"},
             missing_slots: []
           }

    assert Descriptor.extract_slots(descriptor, "analyze") == %{
             extracted_slots: %{},
             missing_slots: [:ticker]
           }
  end
end
