defmodule AllbertAssist.Memory.RetrievalTest do
  @moduledoc """
  v1.3 M9.b.13.a — the Memory read path.

  `Retrieval` had no direct coverage, which is part of why M9.b.10 and M9.b.11
  stayed invisible: both defects manifested here, as a projection that could not
  serve a claim, and the suite had nothing asking this module what it does when
  the projection is unavailable or stale.

  These rows cover the boundaries that do not need a live provider: input
  refusal, the not-ready path, and the Markdown fallback that exists precisely
  so an unavailable projection degrades instead of erroring.
  """

  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Memory.Retrieval
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.KeyCustody

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_home = System.get_env("ALLBERT_HOME")

    root =
      Path.join(System.tmp_dir!(), "allbert-retrieval-#{System.unique_integer([:positive])}")

    Application.delete_env(:allbert_assist, Paths)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    System.put_env("ALLBERT_HOME", root)
    KeyCustody.invalidate(:all)

    on_exit(fn ->
      if original_paths,
        do: Application.put_env(:allbert_assist, Paths, original_paths),
        else: Application.delete_env(:allbert_assist, Paths)

      if original_settings,
        do: Application.put_env(:allbert_assist, Settings, original_settings),
        else: Application.delete_env(:allbert_assist, Settings)

      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      KeyCustody.invalidate(:all)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  describe "input refusal" do
    test "a non-binary query is refused by both entry points" do
      assert {:error, :invalid_memory_query} = Retrieval.projection_search(nil)
      assert {:error, :invalid_memory_query} = Retrieval.projection_search(%{})
      assert {:error, :invalid_memory_query} = Retrieval.markdown_search(nil)
      assert {:error, :invalid_memory_query} = Retrieval.markdown_search(123)
    end

    test "non-keyword options are refused rather than coerced" do
      assert {:error, :invalid_memory_query} = Retrieval.projection_search("juniper", %{})
      assert {:error, :invalid_memory_query} = Retrieval.markdown_search("juniper", %{})
    end
  end

  describe "projection availability" do
    test "an unavailable projection owner reports not ready rather than raising" do
      refute Process.whereis(AllbertAssist.Memory.Projection),
             "this row is only meaningful with no projection owner registered"

      assert {:error, :memory_projection_not_ready} = Retrieval.projection_search("juniper")
    end

    test "the not-ready error is exactly what the operator surface reported in M9.b.10" do
      # `mix allbert admin memory retrieve` surfaced this verbatim on a fresh Home
      # before the bootstrap fix. Pinning it keeps the operator-visible failure
      # stable rather than drifting into an opaque crash.
      assert {:error, :memory_projection_not_ready} =
               Retrieval.projection_search("Project Juniper status summaries")
    end
  end

  describe "markdown fallback" do
    test "an empty Memory root yields no entries instead of an error" do
      assert {:ok, result} = Retrieval.markdown_search("juniper")
      assert result.entries == []
      assert result.scanned_count == 0
    end

    test "a query of only stop words yields no entries" do
      # Lexical.terms/1 reduces this to [], and the fallback must treat that as
      # "match nothing" rather than "match everything".
      assert {:ok, result} = Retrieval.markdown_search("what is the a an and to")
      assert result.entries == []
    end

    test "the fallback reports itself as bounded with an explicit candidate limit" do
      # ADR 0089 keeps this path bounded so it can never become a per-turn full
      # filesystem scan. The numbers are reported, not implied.
      assert {:ok, result} = Retrieval.markdown_search("juniper")
      assert result.bounded? == true
      assert is_integer(result.candidate_limit) and result.candidate_limit > 0
    end
  end
end
