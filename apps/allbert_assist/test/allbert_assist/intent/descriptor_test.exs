defmodule AllbertAssist.Intent.DescriptorTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Intent.Descriptor

  setup :setup_stocksage_registry

  defp setup_stocksage_registry(context), do: AllbertAssist.StockSageRegistryCase.setup(context)

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

  test "normalizes optional workspace destinations for panel handoffs" do
    assert {:ok, descriptor} =
             Descriptor.normalize(%{
               app_id: :allbert,
               action_name: "open_calendar_panel",
               label: "Open Calendar agenda",
               destination: "workspace:calendar",
               examples: ["show me today's agenda"],
               required_slots: []
             })

    assert descriptor.id == "allbert:open_calendar_panel"
    assert descriptor.destination == "workspace:calendar"
    assert descriptor.capability.permission == :read_only
    assert descriptor.capability.confirmation == :not_required
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

  test "extracts bounded title and body phrases from operator syntax" do
    assert {:ok, descriptor} =
             Descriptor.normalize(%{
               app_id: :stocksage,
               action_name: "run_analysis",
               label: "Run StockSage analysis",
               required_slots: [:title, :body],
               slot_extractors: %{title: :title_phrase, body: :body_phrase}
             })

    assert Descriptor.extract_slots(
             descriptor,
             ~s(create a note titled fallback with body hi)
           ) == %{
             extracted_slots: %{title: "fallback", body: "hi"},
             missing_slots: []
           }

    assert Descriptor.extract_slots(
             descriptor,
             "create a note titled groceries with milk and eggs"
           ) == %{
             extracted_slots: %{title: "groceries", body: "milk and eggs"},
             missing_slots: []
           }

    assert Descriptor.extract_slots(descriptor, "create a note titled fallback") == %{
             extracted_slots: %{title: "fallback"},
             missing_slots: [:body]
           }
  end

  test "extracts note paths from read/open note phrases" do
    assert {:ok, descriptor} =
             Descriptor.normalize(%{
               app_id: :notes_files,
               action_name: "read_note",
               label: "Read a local note",
               required_slots: [:path],
               slot_extractors: %{path: :note_path_phrase}
             })

    assert Descriptor.extract_slots(descriptor, "read the scratch note") == %{
             extracted_slots: %{path: "scratch.md"},
             missing_slots: []
           }

    assert Descriptor.extract_slots(descriptor, "open notes/release-checklist") == %{
             extracted_slots: %{path: "notes/release-checklist.md"},
             missing_slots: []
           }
  end

  test "extracts optional slots without making them required" do
    assert {:ok, descriptor} =
             Descriptor.normalize(%{
               app_id: :stocksage,
               action_name: "get_trends",
               label: "Show StockSage trends",
               optional_slots: [:symbol],
               slot_extractors: %{symbol: :ticker_symbol}
             })

    assert descriptor.required_slots == []
    assert descriptor.optional_slots == [:symbol]
    assert descriptor.slot_extractors == %{symbol: :ticker_symbol}

    assert Descriptor.extract_slots(descriptor, "show trends for AAPL") == %{
             extracted_slots: %{symbol: "AAPL"},
             missing_slots: []
           }

    assert Descriptor.extract_slots(descriptor, "show trends") == %{
             extracted_slots: %{},
             missing_slots: []
           }
  end

  # v0.54 M9.1 (ADR 0062 Option 1): core actions carry app_id: nil but are
  # descriptorizable under the reserved :allbert id.
  test "normalizes a core (app_id: nil) action under the reserved :allbert id" do
    assert {:ok, descriptor} =
             Descriptor.normalize(%{
               app_id: :allbert,
               action_name: "append_memory",
               label: "Remember a fact in memory",
               examples: ["remember that my anniversary is June 20"],
               synonyms: ["remember"],
               required_slots: []
             })

    assert descriptor.id == "allbert:append_memory"
    assert descriptor.capability.exposure == :agent
  end

  test "still rejects a descriptor whose action is genuinely internal" do
    # delete_memory_entry is exposure: :internal — must not be descriptorizable.
    assert {:error, %{reason: {:action_not_agent_exposed, "delete_memory_entry"}}} =
             Descriptor.normalize(%{
               app_id: :allbert,
               action_name: "delete_memory_entry",
               label: "Bad internal descriptor",
               required_slots: []
             })
  end
end
