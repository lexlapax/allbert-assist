defmodule AllbertAssist.Intent.RouterDisambiguatorTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Intent.Router
  alias AllbertAssist.Intent.Router.Disambiguator
  alias AllbertAssist.Intent.Router.Disambiguator.FakeDisambiguator
  alias AllbertAssist.Intent.Router.Embedder.FakeEmbedder
  alias AllbertAssist.Intent.Router.Outcome
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @shortlist [
    %{action_name: "create_note", app_id: :notes, label: "Create note"},
    %{action_name: "search_notes", app_id: :notes, label: "Search notes"}
  ]
  @opts [min_confidence: 0.6, disambiguation_margin: 0.12]

  setup do
    original = %{
      home: System.get_env("ALLBERT_HOME"),
      paths: Application.get_env(:allbert_assist, Paths),
      settings: Application.get_env(:allbert_assist, Settings),
      embedder: Application.get_env(:allbert_assist, :intent_router_embedder),
      disambiguator: Application.get_env(:allbert_assist, :intent_router_disambiguator),
      selection: Application.get_env(:allbert_assist, :intent_router_fake_selection)
    }

    System.put_env("ALLBERT_HOME", Path.join(System.tmp_dir!(), "allbert-router-disamb-#{System.unique_integer([:positive])}"))
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)
    Application.put_env(:allbert_assist, :intent_router_embedder, FakeEmbedder)
    Application.put_env(:allbert_assist, :intent_router_disambiguator, FakeDisambiguator)
    Application.delete_env(:allbert_assist, :intent_router_embedder_error)

    on_exit(fn ->
      if original.home, do: System.put_env("ALLBERT_HOME", original.home), else: System.delete_env("ALLBERT_HOME")
      restore(Paths, original.paths)
      restore(Settings, original.settings)
      restore(:intent_router_embedder, original.embedder)
      restore(:intent_router_disambiguator, original.disambiguator)
      restore(:intent_router_fake_selection, original.selection)
    end)

    :ok
  end

  describe "decide/4 confidence gate (pure)" do
    test "high-confidence real action with a clear margin executes" do
      assert %Outcome{kind: :execute, action_name: "create_note", confidence: 0.9} =
               Disambiguator.decide(%{selected: "create_note", confidence: 0.9}, @shortlist, 0.5, @opts)
    end

    test "low confidence clarifies" do
      assert %Outcome{kind: :clarify} =
               Disambiguator.decide(%{selected: "create_note", confidence: 0.3}, @shortlist, 0.5, @opts)
    end

    test "ambiguous margin clarifies even at high confidence" do
      assert %Outcome{kind: :clarify} =
               Disambiguator.decide(%{selected: "create_note", confidence: 0.95}, @shortlist, 0.05, @opts)
    end

    test "a selection outside the shortlist clarifies (never executes a hallucination)" do
      assert %Outcome{kind: :clarify} =
               Disambiguator.decide(%{selected: "delete_everything", confidence: 0.99}, @shortlist, 0.5, @opts)
    end

    test "sentinels map to clarify / answer / none" do
      assert %Outcome{kind: :clarify} = Disambiguator.decide(%{selected: "__clarify__", confidence: 0.9}, @shortlist, 0.5, @opts)
      assert %Outcome{kind: :answer} = Disambiguator.decide(%{selected: "__answer__"}, @shortlist, 0.5, @opts)
      assert %Outcome{kind: :none} = Disambiguator.decide(%{selected: "__none__"}, @shortlist, 0.5, @opts)
    end
  end

  describe "disambiguate/5 dispatch" do
    test "maps a model selection to an outcome" do
      Application.put_env(:allbert_assist, :intent_router_fake_selection, {:ok, %{selected: "create_note", confidence: 0.9}})
      assert {:ok, %Outcome{kind: :execute, action_name: "create_note"}} =
               Disambiguator.disambiguate("create a note", @shortlist, 0.5, %{}, @opts)
    end

    test "defers when the selection model is unavailable" do
      Application.put_env(:allbert_assist, :intent_router_fake_selection, {:error, :timeout})
      assert {:ok, %Outcome{kind: :defer, reason: :disambiguator_unavailable}} =
               Disambiguator.disambiguate("create a note", @shortlist, 0.5, %{}, @opts)
    end
  end

  describe "Router full path (Stage 1 -> Stage 2)" do
    test "routes a request end-to-end to :answer via fakes" do
      {:ok, _} = Settings.put("intent.router_strategy", "two_stage_local", %{audit?: false})
      Application.put_env(:allbert_assist, :intent_router_fake_selection, {:ok, %{selected: "__answer__", confidence: 0.9}})
      assert {:ok, %Outcome{kind: :answer}} = Router.route(%{text: "hello there"}, [])
    end
  end

  defp restore(key, nil) when is_atom(key), do: Application.delete_env(:allbert_assist, key)
  defp restore(key, value), do: Application.put_env(:allbert_assist, key, value)
end
