defmodule AllbertAssist.Intent.RouterPrefilterTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Intent.Router
  alias AllbertAssist.Intent.Router.Disambiguator.FakeDisambiguator
  alias AllbertAssist.Intent.Router.Embedder.FakeEmbedder
  alias AllbertAssist.Intent.Router.Outcome
  alias AllbertAssist.Intent.Router.Prefilter
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_embedder = Application.get_env(:allbert_assist, :intent_router_embedder)
    original_error = Application.get_env(:allbert_assist, :intent_router_embedder_error)
    original_override = Application.get_env(:allbert_assist, :intent_router_strategy_override)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-router-prefilter-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)
    Application.put_env(:allbert_assist, :intent_router_embedder, FakeEmbedder)
    Application.delete_env(:allbert_assist, :intent_router_embedder_error)

    on_exit(fn ->
      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      restore(Paths, original_paths)
      restore(Settings, original_settings)
      restore(:intent_router_embedder, original_embedder)
      restore(:intent_router_embedder_error, original_error)
      restore(:intent_router_strategy_override, original_override)
    end)

    :ok
  end

  describe "rank/3 (pure cosine ranking)" do
    test "ranks by similarity, takes top-k, and reports a margin" do
      entries = [
        entry("create_note", :notes, "Create note", "create note write new"),
        entry("search_notes", :notes, "Search notes", "search find lookup notes"),
        entry("open_url", :browser, "Open URL", "open url browser web page")
      ]

      query = FakeEmbedder.vector("create a new note please")
      result = Prefilter.rank(query, entries, 2)

      assert length(result.shortlist) == 2
      assert hd(result.shortlist).action_name == "create_note"
      assert result.margin >= 0.0
      # scores are sorted descending
      [%{score: s1}, %{score: s2}] = result.shortlist
      assert s1 >= s2
    end
  end

  describe "shortlist/2 (embed + index)" do
    test "falls back when the embedder is unavailable" do
      Application.put_env(:allbert_assist, :intent_router_embedder_error, :down)
      assert {:fallback, _reason} = Prefilter.shortlist("create a note")
    end

    test "a create-a-note request shortlists write_note (M6 descriptor-coverage fix)" do
      AllbertAssist.Intent.Router.Index.rebuild()

      assert {:ok, %{shortlist: shortlist}} =
               Prefilter.shortlist("create a note titled groceries with milk")

      scores = Map.new(shortlist, fn s -> {s.action_name, s.score} end)

      assert Map.has_key?(scores, "write_note"),
             "write_note should be shortlisted for a create request"

      write_note = Enum.find(shortlist, &(&1.action_name == "write_note"))
      assert write_note.extracted_slots.title == "groceries"
      assert write_note.extracted_slots.body == "milk"

      # the original mis-route: write_note must not lose to search_notes
      if Map.has_key?(scores, "search_notes") do
        assert scores["write_note"] >= scores["search_notes"]
      end

      if Map.has_key?(scores, "read_note") do
        assert scores["write_note"] >= scores["read_note"]
      end
    end

    test "a read-note request shortlists read_note with a path slot" do
      AllbertAssist.Intent.Router.Index.rebuild()

      assert {:ok, %{shortlist: shortlist}} = Prefilter.shortlist("read the scratch note")

      read_note = Enum.find(shortlist, &(&1.action_name == "read_note"))

      assert read_note
      assert read_note.extracted_slots.path == "scratch.md"
      assert read_note.missing_slots == []
    end
  end

  describe "DefaultRouter (Stage 1 feeds Stage 2)" do
    test "defers to the deterministic ladder when the Stage 2 model is unavailable" do
      Application.put_env(:allbert_assist, :intent_router_strategy_override, :two_stage_local)
      # Deterministically simulate an unavailable Stage 2 model (independent of
      # whether a local Ollama happens to be running): the fake selection boundary
      # returns {:error, _} when no selection is configured, so the router defers.
      prev_disamb = Application.get_env(:allbert_assist, :intent_router_disambiguator)
      prev_sel = Application.get_env(:allbert_assist, :intent_router_fake_selection)
      Application.put_env(:allbert_assist, :intent_router_disambiguator, FakeDisambiguator)
      Application.delete_env(:allbert_assist, :intent_router_fake_selection)

      on_exit(fn ->
        restore(:intent_router_disambiguator, prev_disamb)
        restore(:intent_router_fake_selection, prev_sel)
      end)

      assert {:ok, %Outcome{kind: :defer}} = Router.route(%{text: "create a note"}, [])
    end
  end

  defp entry(action, app, label, text) do
    %{action_name: action, app_id: app, label: label, vector: FakeEmbedder.vector(text)}
  end

  defp restore(key, nil) when is_atom(key), do: Application.delete_env(:allbert_assist, key)
  defp restore(key, value), do: Application.put_env(:allbert_assist, key, value)
end
