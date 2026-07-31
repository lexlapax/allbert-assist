defmodule AllbertAssist.Intent.SelectionPolicyTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Intent.{Decision, Descriptor, SelectionPolicy}
  alias AllbertAssist.Intent.Router.DescriptorResolver

  @quoted_preference_prompt "What day and time does this sentence say I prefer for Project Juniper status summaries? I prefer Friday at 09:00, valid starting 2026-06-01. The validation marker is juniper-v13-primary. Answer in one sentence."

  test "derives protected Memory policy from the canonical descriptor" do
    assert %{
             accepted?: true,
             policy: :explicit_evidence,
             resolution: :resolved
           } = SelectionPolicy.evaluate("append_memory", "Remember that Juniper is due Friday.")

    refute SelectionPolicy.evaluate(
             "append_memory",
             ~s(Summarize this quoted sentence: "Remember that Juniper is due Friday.")
           ).accepted?

    for prompt <- [
          "Remember my password.",
          "Remember my password?",
          "Remember my API key!",
          "Remember my token, please.",
          "Remember my password？",
          "Remember my API key！",
          "Remember my password🙂"
        ] do
      result = SelectionPolicy.evaluate("append_memory", prompt)
      assert result.evidence.negative_text_match?, prompt
      refute result.accepted?, prompt
    end
  end

  test "human-reviewed polite operator acts remain explicit while referential text is rejected" do
    for prompt <- [
          "Please remember that Juniper is due Friday.",
          "Remember, Juniper is due Friday.",
          "Could you remember that Juniper is due Friday?",
          "Can you keep in mind that Juniper is due Friday?",
          "Would you please save this to memory: Juniper is due Friday?",
          "Save this: Juniper is due Friday.",
          "Store that in memory: Juniper is due Friday.",
          "Note this: Juniper is due Friday."
        ] do
      assert SelectionPolicy.evaluate("append_memory", prompt).accepted?, prompt
    end

    for prompt <- [
          "Could you remember what I told you about Juniper?",
          ~s(Could you summarize this quoted sentence: "Remember that Juniper is due Friday."),
          "Please explain the phrase remember that without storing anything.",
          ~s("Remember that Juniper is due Friday."),
          "“Remember that Juniper is due Friday.”",
          "`Remember that Juniper is due Friday.`",
          "(Remember that Juniper is due Friday.)",
          "[Remember that Juniper is due Friday.]",
          ~s(\\"Remember that Juniper is due Friday.\\"),
          "- Remember that Juniper is due Friday.",
          "/Remember that Juniper is due Friday."
        ] do
      refute SelectionPolicy.evaluate("append_memory", prompt).accepted?, prompt
    end

    for prompt <- [
          ~s("What do you remember about me?"),
          "“What do you remember about me?”",
          "`What do you remember about me?`"
        ] do
      refute SelectionPolicy.evaluate("read_recent_memory", prompt).accepted?, prompt
    end

    assert SelectionPolicy.evaluate(
             "read_recent_memory",
             "Could you tell me what you remember about Juniper?"
           ).accepted?

    assert SelectionPolicy.evaluate("read_recent_memory", "What do you remember?").accepted?

    for prompt <- [
          "Show recent memory",
          "List recent memory",
          "What can you recall about Juniper?",
          "Read my memory",
          "Please show my memory"
        ] do
      assert SelectionPolicy.evaluate("read_recent_memory", prompt).accepted?, prompt
    end

    for prompt <- [
          "my name is Sandeep",
          "I prefer short implementation updates.",
          "my timezone is America/Los_Angeles"
        ] do
      assert SelectionPolicy.deterministic_action_accepted?("append_memory", prompt), prompt
    end

    for prompt <- [
          "what is my name?",
          "how should you update me?",
          "what timezone am I in?",
          "what time zone am I in?",
          "how do I like to test?"
        ] do
      assert SelectionPolicy.deterministic_action_accepted?("read_recent_memory", prompt), prompt
    end
  end

  test "fails closed when a proposed action has no resolved descriptor" do
    assert %{
             accepted?: false,
             policy: :unresolved,
             resolution: :unresolved
           } =
             SelectionPolicy.evaluate("append_memory", "Remember this", descriptors: [])
  end

  test "semantic proposals require descriptor or complete declared-slot evidence" do
    descriptors = DescriptorResolver.resolve()

    assert SelectionPolicy.evaluate("read_setting", "Show setting operator.timezone",
             descriptors: descriptors
           ).accepted?

    refute SelectionPolicy.evaluate("read_setting", @quoted_preference_prompt,
             descriptors: descriptors
           ).accepted?

    slot_descriptor = %Descriptor{
      id: "test:semantic_probe",
      app_id: :allbert,
      action_name: "semantic_probe",
      label: "Run semantic probe",
      required_slots: [:symbol],
      slot_extractors: %{symbol: :ticker_symbol}
    }

    refute SelectionPolicy.evaluate("semantic_probe", "Please inspect AAPL",
             descriptors: [slot_descriptor]
           ).accepted?

    refute SelectionPolicy.evaluate("semantic_probe", "Please inspect this",
             descriptors: [slot_descriptor]
           ).accepted?

    slot_opt_in_descriptor = %{
      slot_descriptor
      | vocabulary: %{allow_required_slot_selection: true}
    }

    assert SelectionPolicy.evaluate("semantic_probe", "Please inspect AAPL",
             descriptors: [slot_opt_in_descriptor]
           ).accepted?

    negative_slot_descriptor = %{
      slot_descriptor
      | vocabulary: %{
          allow_required_slot_selection: true,
          negative_phrases: ["show stock analysis"]
        }
    }

    refute SelectionPolicy.evaluate("semantic_probe", "show stock analysis AAPL",
             descriptors: [negative_slot_descriptor]
           ).accepted?
  end

  test "semantic proposal evidence is stricter than fuzzy ranking affinity" do
    descriptors = [
      %Descriptor{
        id: "test:read_setting",
        app_id: :allbert,
        action_name: "read_setting",
        label: "Read one setting",
        synonyms: ["read setting", "show setting"]
      },
      %Descriptor{
        id: "test:write_note",
        app_id: :notes_files,
        action_name: "write_note",
        label: "Write a note",
        synonyms: ["write note", "create note"]
      },
      %Descriptor{
        id: "test:search_notes",
        app_id: :notes_files,
        action_name: "search_notes",
        label: "Search notes",
        synonyms: ["search notes", "find notes"]
      }
    ]

    refute SelectionPolicy.evaluate(
             "read_setting",
             "Read this sentence and answer without changing any setting.",
             descriptors: descriptors
           ).accepted?

    refute SelectionPolicy.evaluate(
             "write_note",
             "Write a critique of this note without creating anything.",
             descriptors: descriptors
           ).accepted?

    refute SelectionPolicy.evaluate(
             "search_notes",
             "Explain what search notes means in this documentation.",
             descriptors: descriptors
           ).accepted?

    for prompt <- [
          "Please tell me what search notes means.",
          "Could you compare search notes with read note.",
          "Discuss search notes in the documentation.",
          "What is meant by search notes?",
          ~s("search notes"),
          "Do not search notes"
        ] do
      refute SelectionPolicy.evaluate("search_notes", prompt, descriptors: descriptors).accepted?,
             prompt
    end

    slot_descriptor = %Descriptor{
      id: "test:run_analysis",
      app_id: :stocksage,
      action_name: "run_analysis",
      label: "Run StockSage analysis",
      synonyms: ["analyze", "stock analysis"],
      required_slots: [:ticker],
      slot_extractors: %{ticker: :ticker_symbol}
    }

    for prompt <- ["What is AAPL?", "Tell me whether AAPL is a stock ticker."] do
      refute SelectionPolicy.evaluate("run_analysis", prompt, descriptors: [slot_descriptor]).accepted?,
             prompt
    end
  end

  test "only a structurally consistent direct-answer decision bypasses proposal policy" do
    assert SelectionPolicy.decision_accepted?(
             %Decision{intent: :direct_answer, selected_action: "direct_answer"},
             "What is two plus two?"
           )

    refute SelectionPolicy.decision_accepted?(
             %Decision{intent: :direct_answer, selected_action: "append_memory"},
             "Quoted action language"
           )

    refute SelectionPolicy.decision_accepted?(
             %Decision{intent: :direct_answer, selected_action: nil},
             "What is two plus two?"
           )
  end

  test "multi-action checks are total and fail closed for malformed shortlists" do
    descriptors = DescriptorResolver.resolve()

    assert SelectionPolicy.accept_all?(
             ["read_recent_memory"],
             "What do you remember about Juniper?",
             descriptors: descriptors
           )

    assert SelectionPolicy.accept_any?(
             ["read_recent_memory", "read_setting"],
             "What do you remember about Juniper?",
             descriptors: descriptors
           )

    assert SelectionPolicy.supported_action_names(
             ["read_recent_memory", "read_setting"],
             "What do you remember about Juniper?",
             descriptors: descriptors
           ) == ["read_recent_memory"]

    refute SelectionPolicy.accept_all?(
             ["read_recent_memory", "read_setting"],
             "What do you remember about Juniper?",
             descriptors: descriptors
           )

    refute SelectionPolicy.accept_all?(
             ["read_recent_memory" | :malformed_tail],
             "What do you remember about Juniper?",
             descriptors: descriptors
           )

    refute SelectionPolicy.accept_all?(
             ["read_recent_memory", :malformed],
             "What do you remember about Juniper?",
             descriptors: descriptors
           )
  end

  test "category vocabulary grounds clarification without authorizing execution" do
    descriptor = %Descriptor{
      id: "test:write_note",
      app_id: :notes_files,
      action_name: "write_note",
      label: "Write a note",
      synonyms: ["write note", "create note"],
      vocabulary: %{clarification_phrases: ["note"]}
    }

    refute SelectionPolicy.evaluate("write_note", "note", descriptors: [descriptor]).accepted?

    assert SelectionPolicy.supported_action_names(["write_note"], "note",
             descriptors: [descriptor]
           ) == ["write_note"]
  end
end
