defmodule AllbertAssist.Intent.Eval.RunnerTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Intent.Eval.Corpus
  alias AllbertAssist.Intent.Eval.Runner
  alias AllbertAssist.Intent.Descriptor
  alias AllbertAssist.Intent.Router.Embedder.FakeEmbedder

  test "replays corpus cases deterministically through Stage-1 ranking" do
    cases = [
      case!("notes-create-001", "notes", "create a note about groceries", :execute, "write_note")
    ]

    entries = [
      %{
        action_name: "write_note",
        app_id: :notes,
        label: "Write note",
        text: "create write note groceries"
      },
      %{
        action_name: "search_notes",
        app_id: :notes,
        label: "Search notes",
        text: "find search notes onboarding"
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

  test "semantic fake selector clarifies bare model/settings noun phrases" do
    case = case!("settings-ambiguous", "settings", "model settings", :clarify, nil)

    entries = [
      %{
        action_name: "set_active_model_profile",
        app_id: :allbert,
        label: "Switch model profile",
        text: "set active model profile"
      },
      %{
        action_name: "list_model_profiles",
        app_id: :allbert,
        label: "List model profiles",
        text: "list model profiles"
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
        required_slots: [:title, :body]
      },
      %{
        action_name: "read_note",
        app_id: :notes_files,
        label: "Read note",
        text: "read note",
        required_slots: [:path]
      }
    ]

    assert [%{actual: %{kind: :clarify, action: nil}}] =
             Runner.run([case], entries: entries, embedder: FakeEmbedder).results
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
