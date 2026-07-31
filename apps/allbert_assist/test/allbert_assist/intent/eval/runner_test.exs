defmodule AllbertAssist.Intent.Eval.RunnerTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Intent.Descriptor
  alias AllbertAssist.Intent.Eval.Corpus
  alias AllbertAssist.Intent.Eval.Runner
  alias AllbertAssist.Intent.Router.Embedder.FakeEmbedder

  defmodule AppendSelector do
    def select(_utterance, _shortlist, _context, _opts) do
      {:ok, %{selected: "append_memory", confidence: 1.0, slots: %{}}}
    end
  end

  defmodule ReadSettingSelector do
    def select(_utterance, _shortlist, _context, _opts) do
      {:ok, %{selected: "read_setting", confidence: 1.0, slots: %{}}}
    end
  end

  test "replays corpus cases deterministically through Stage-1 ranking" do
    cases = [
      case!("notes-create-001", "notes", "create a note about groceries", :execute, "write_note")
    ]

    entries = [
      %{
        action_name: "write_note",
        app_id: :notes,
        label: "Write note",
        text: "create write note groceries",
        synonyms: ["create note", "create a note"]
      },
      %{
        action_name: "search_notes",
        app_id: :notes,
        label: "Search notes",
        text: "find search notes onboarding",
        synonyms: ["search notes"]
      }
    ]

    run1 = Runner.run(cases, entries: entries, embedder: FakeEmbedder)
    run2 = Runner.run(cases, entries: entries, embedder: FakeEmbedder)

    assert run1 == run2

    assert [%{actual: %{kind: :execute, action: "write_note"}, shortlist: shortlist}] =
             run1.results

    assert hd(shortlist).action_name == "write_note"
  end

  test "filters surface-specific runs while keeping :any cases" do
    cases = [
      case!("notes-any", "notes", "create a note", :execute, "write_note"),
      case!("notes-web", "notes", "search notes", :execute, "search_notes", :web),
      case!("notes-tui", "notes", "read notes", :execute, "read_note", :tui)
    ]

    run = Runner.run(cases, entries: [], surface: :tui)

    assert Enum.map(run.results, & &1.case.id) == ["notes-any", "notes-tui"]
  end

  test "uses the case utterance for deterministic slot extraction" do
    case =
      case!(
        "email-send-001",
        "email",
        "send an email to alice@example.com about lunch",
        :execute,
        "send_email"
      )

    {:ok, descriptor} =
      Descriptor.normalize(%{
        app_id: :allbert,
        action_name: "send_email",
        label: "Send email",
        examples: ["send email to alice@example.com about lunch"],
        synonyms: ["send an email"],
        required_slots: [:to, :body],
        slot_extractors: %{to: :email_address, body: :message_body_phrase}
      })

    assert [%{actual: %{kind: :execute, action: "send_email", slots: slots}}] =
             Runner.run([case], descriptors: [descriptor], embedder: FakeEmbedder).results

    assert slots == %{to: "alice@example.com", body: "lunch"}
  end

  test "semantic fake selector can produce answer and none sentinels" do
    answer = case!("answer-001", "answer", "what is the capital of France", :answer, nil)
    slash = case!("slash-001", "negative-slash", "/settings get operator.timezone", :none, nil)

    run = Runner.run([answer, slash], entries: [], embedder: FakeEmbedder)

    assert [
             %{actual: %{kind: :answer, action: nil}},
             %{actual: %{kind: :none, action: nil}}
           ] = run.results
  end

  test "shared descriptor policy rejects unsupported action proposals in replay" do
    explicit =
      case!(
        "memory-explicit",
        "memory",
        "Remember that Project Juniper summaries are due Friday",
        :execute,
        "append_memory"
      )

    quoted =
      case!(
        "memory-quoted",
        "memory",
        ~s(Summarize this quoted sentence: "Remember that summaries are due Friday."),
        :answer,
        nil
      )

    {:ok, descriptor} =
      Descriptor.normalize(%{
        app_id: :allbert,
        action_name: "append_memory",
        label: "Remember a fact in memory",
        synonyms: ["remember", "note to self"],
        required_slots: [:memory],
        slot_extractors: %{memory: :memory_phrase},
        selection_policy: :explicit_evidence
      })

    assert [
             %{actual: %{kind: :execute, action: "append_memory"}},
             %{
               actual: %{
                 kind: :answer,
                 action: nil,
                 diagnostics: %{selection_rejected?: true}
               }
             }
           ] =
             Runner.run([explicit, quoted],
               descriptors: [descriptor],
               disambiguator: AppendSelector
             ).results
  end

  test "semantic setting proposals require canonical descriptor evidence in replay" do
    juniper =
      case!(
        "semantic-setting-juniper",
        "settings",
        "What day and time does this sentence say I prefer for Project Juniper status summaries? I prefer Friday at 09:00, valid starting 2026-06-01. The validation marker is juniper-v13-primary. Answer in one sentence.",
        :answer,
        nil
      )

    explicit =
      case!(
        "semantic-setting-explicit",
        "settings",
        "read setting operator.timezone",
        :execute,
        "read_setting"
      )

    {:ok, descriptor} =
      Descriptor.normalize(%{
        app_id: :allbert,
        action_name: "read_setting",
        label: "Read one setting",
        examples: ["read setting operator.timezone"],
        synonyms: ["read setting", "show setting", "get setting"]
      })

    assert [
             %{
               actual: %{
                 kind: :answer,
                 action: nil,
                 diagnostics: %{selection_rejected?: true}
               }
             },
             %{actual: %{kind: :execute, action: "read_setting"}}
           ] =
             Runner.run([juniper, explicit],
               descriptors: [descriptor],
               disambiguator: ReadSettingSelector
             ).results
  end

  test "legacy selector test seam cannot bypass descriptor selection policy" do
    quoted =
      case!(
        "memory-selector-quoted",
        "memory",
        ~s(Summarize this quoted sentence: "Remember that summaries are due Friday."),
        :answer,
        nil
      )

    {:ok, descriptor} =
      Descriptor.normalize(%{
        app_id: :allbert,
        action_name: "append_memory",
        label: "Remember a fact in memory",
        synonyms: ["remember"],
        selection_policy: :explicit_evidence
      })

    selector = fn _case, _shortlist ->
      %{kind: :execute, action: "append_memory", diagnostics: %{advisory: true}}
    end

    assert [
             %{
               actual: %{
                 kind: :answer,
                 action: nil,
                 diagnostics: %{selection_rejected?: true}
               }
             }
           ] = Runner.run([quoted], descriptors: [descriptor], selector: selector).results
  end

  test "semantic fake selector clarifies bare model/settings noun phrases" do
    case = case!("settings-ambiguous", "settings", "model settings", :clarify, nil)

    entries = [
      %{
        action_name: "set_active_model_profile",
        app_id: :allbert,
        label: "Switch model profile",
        text: "set active model profile",
        vocabulary: %{clarification_phrases: ["model settings"]}
      },
      %{
        action_name: "list_model_profiles",
        app_id: :allbert,
        label: "List model profiles",
        text: "list model profiles",
        vocabulary: %{clarification_phrases: ["model settings"]}
      }
    ]

    assert [%{actual: %{kind: :clarify, action: nil}}] =
             Runner.run([case], entries: entries, embedder: FakeEmbedder).results
  end

  test "single-word domain ambiguity clarifies instead of falling to none" do
    case = case!("notes-ambiguous", "notes", "note", :clarify, nil)

    entries = [
      %{
        action_name: "write_note",
        app_id: :notes_files,
        label: "Write note",
        text: "write note",
        required_slots: [:title, :body],
        vocabulary: %{clarification_phrases: ["note"]}
      },
      %{
        action_name: "read_note",
        app_id: :notes_files,
        label: "Read note",
        text: "read note",
        required_slots: [:path],
        vocabulary: %{clarification_phrases: ["note"]}
      }
    ]

    assert [%{actual: %{kind: :clarify, action: nil}}] =
             Runner.run([case], entries: entries, embedder: FakeEmbedder).results
  end

  test "clarify replay strictly validates the selector shortlist instead of ranked noise" do
    case = case!("notes-clarify-policy", "notes", "note", :answer, nil)

    entries = [
      %{
        action_name: "write_note",
        app_id: :notes_files,
        label: "Write note",
        text: "write note",
        vocabulary: %{clarification_phrases: ["note"]}
      },
      %{
        action_name: "read_setting",
        app_id: :allbert,
        label: "Read setting",
        text: "read setting"
      }
    ]

    unrelated_selector = fn _case, _ranked ->
      %{
        kind: :clarify,
        action: nil,
        shortlist: [%{action_name: "read_setting", label: "Read setting"}]
      }
    end

    malformed_selector = fn _case, _ranked ->
      %{
        kind: :clarify,
        action: nil,
        shortlist: [
          %{action_name: "write_note", label: "Write note"},
          %{label: "missing action"}
        ]
      }
    end

    for selector <- [unrelated_selector, malformed_selector] do
      assert [%{actual: %{kind: :answer, action: nil}}] =
               Runner.run([case], entries: entries, selector: selector).results
    end
  end

  defp case!(id, domain, utterance, kind, action, surface \\ :any) do
    {:ok, case} =
      Corpus.validate(%{
        id: id,
        domain: domain,
        surface: surface,
        utterance: utterance,
        expected: %{kind: kind, action: action}
      })

    case
  end
end
