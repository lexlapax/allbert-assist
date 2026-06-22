defmodule AllbertAssist.Intent.Eval.CorpusTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Intent.Eval.Corpus

  test "loads and normalizes YAML corpus cases" do
    root = tmp_dir("corpus-ok")
    File.mkdir_p!(Path.join(root, "notes"))

    path = Path.join(root, "notes/create.yaml")

    File.write!(path, """
    schema_version: 1
    id: notes-create-001
    domain: notes
    surface: tui
    utterance: create a note titled groceries
    context:
      thread_id: test-thread
    expected:
      kind: execute
      action: write_note
      slots:
        title: groceries
    rationale: explicit create
    """)

    assert {:ok, [case]} = Corpus.load(path: root)
    assert case.id == "notes-create-001"
    assert case.domain == "notes"
    assert case.surface == :tui
    assert case.expected.kind == :execute
    assert case.expected.action == "write_note"
    assert case.expected.slots == %{"title" => "groceries"}
    assert case.context == %{"thread_id" => "test-thread"}
    assert case.path == path
  end

  test "loads the migrated committed golden corpus" do
    assert {:ok, cases} = Corpus.load()
    assert length(cases) >= 30
    assert Enum.any?(cases, &(&1.id == "notes-create-001" and &1.domain == "notes"))

    assert Enum.any?(
             cases,
             &(&1.id == "stocks-analyze-001" and &1.expected.slots == %{"ticker" => :present})
           )
  end

  test "loads a list-style migrated fixture and slot presence expectations" do
    root = tmp_dir("corpus-list")
    File.mkdir_p!(Path.join(root, "stocks"))
    path = Path.join(root, "stocks/anchors.yaml")

    File.write!(path, """
    cases:
      - id: stocks-analyze-001
        domain: stocks
        utterance: analyze AAPL
        expected:
          kind: execute
          action: run_analysis
          slots:
            - ticker
    """)

    assert {:ok, [case]} = Corpus.load(path: root)
    assert case.expected.slots == %{"ticker" => :present}
  end

  test "ignores baseline artifacts while loading corpus directories" do
    root = tmp_dir("corpus-baseline")
    File.mkdir_p!(Path.join(root, "notes"))

    File.write!(Path.join(root, "baseline.yaml"), "overall_accuracy: 0.0\n")

    File.write!(Path.join(root, "notes/create.yaml"), """
    id: notes-create-001
    domain: notes
    utterance: create a note
    expected:
      kind: execute
      action: write_note
    """)

    assert {:ok, [case]} = Corpus.load(path: root)
    assert case.id == "notes-create-001"
  end

  test "rejects unsafe non-yaml corpus paths" do
    root = tmp_dir("corpus-unsafe")
    File.mkdir_p!(root)
    path = Path.join(root, "not-yaml.txt")
    File.write!(path, "nope")

    assert {:error, :unsafe_corpus_path} = Corpus.load(path: path)
  end

  test "validates expected execute action and surface" do
    assert {:error, {:missing_expected_action, nil}} =
             Corpus.validate(%{
               "id" => "bad",
               "domain" => "notes",
               "surface" => "tui",
               "utterance" => "create a note",
               "expected" => %{"kind" => "execute"}
             })

    assert {:error, {:invalid_surface, "operator-console"}} =
             Corpus.validate(%{
               "id" => "bad",
               "domain" => "notes",
               "surface" => "operator-console",
               "utterance" => "create a note",
               "expected" => %{"kind" => "none"}
             })
  end

  defp tmp_dir(prefix) do
    Path.join(
      System.tmp_dir!(),
      "allbert-intent-eval-#{prefix}-#{System.unique_integer([:positive])}"
    )
  end
end
