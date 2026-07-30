defmodule AllbertAssist.Search.GenerationTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Conversations
  alias AllbertAssist.Search.Projection
  alias AllbertAssist.Search.Query
  alias AllbertAssist.Settings

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-search-generation-#{System.unique_integer([:positive])}"
      )

    projection_root = Path.join(root, "projection")
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    start_supervised!({Projection, root: projection_root, name: Projection})

    on_exit(fn ->
      restore_env(Settings, original_settings)
      File.rm_rf!(root)
    end)

    %{projection_root: projection_root}
  end

  test "startup recovers the retained verified previous generation", %{projection_root: root} do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Recovery")

    assert {:ok, first} =
             Conversations.append_user_message(thread, "first generation source",
               metadata: %{"channel" => "tui"}
             )

    assert {:ok, first_build} = Projection.rebuild("alice")

    assert {:ok, _second} =
             Conversations.append_user_message(thread, "second generation source",
               metadata: %{"channel" => "tui"}
             )

    assert {:ok, second_build} = Projection.rebuild("alice")
    refute second_build.generation_id == first_build.generation_id
    assert File.exists?(Path.join(root, "previous.sqlite3"))

    stop_supervised(Projection)
    File.write!(Path.join(root, "current.sqlite3"), "corrupt")
    start_supervised!({Projection, root: root, name: Projection})

    assert %{ready?: true, state: "degraded", generation: generation} = Projection.status()
    assert generation.generation_id == first_build.generation_id

    assert {:ok, query} = Query.parse(%{query: "generation"})
    assert {:ok, page} = Projection.candidates(query)
    assert Enum.map(page.candidates, & &1.source_id) == [first.id]
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
