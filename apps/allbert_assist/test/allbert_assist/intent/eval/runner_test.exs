defmodule AllbertAssist.Intent.Eval.RunnerTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Intent.Eval.Corpus
  alias AllbertAssist.Intent.Eval.Runner
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
