defmodule AllbertAssist.Search.ProjectionTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Conversations.Message
  alias AllbertAssist.Search.Projection
  alias AllbertAssist.Search.Query
  alias AllbertAssist.Search.SQLite
  alias AllbertAssist.Settings

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-search-projection-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    start_supervised!({Projection, root: Path.join(root, "projection"), name: Projection})

    on_exit(fn ->
      restore_env(Settings, original_settings)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "rebuild projects redacted Corpus documents and returns deterministic locator candidates" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Search")
    assert {:ok, first} = local_message(thread, "Café release notes shipped safely")
    assert {:ok, second} = local_message(thread, "Unrelated planning update")

    assert {:ok, build} = Projection.rebuild("alice")
    assert build.document_count == 2
    assert build.projection_revision == 1

    assert {:ok, query} = Query.parse(%{query: ~s("release notes" ship*), order: :relevance})
    assert {:ok, page} = Projection.candidates(query)
    assert [%{source_id: source_id, content_digest: digest}] = page.candidates
    assert source_id == first.id
    assert String.starts_with?(digest, "sha256:")
    assert page.generation_id == build.generation_id

    refute Enum.any?(page.candidates, &Map.has_key?(&1, :searchable_text))
    refute Enum.any?(page.candidates, &Map.has_key?(&1, :snippet))

    assert {:ok, newest} = Query.parse(%{query: "update", order: :newest})
    assert {:ok, %{candidates: [%{source_id: newest_id}]}} = Projection.candidates(newest)
    assert newest_id == second.id
  end

  test "duplicate upsert preserves the locator row and first revision while delete removes both rows" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Mutation")
    assert {:ok, message} = local_message(thread, "first searchable value")
    assert {:ok, _build} = Projection.rebuild("alice")

    path = Path.join([root_for_projection(), "current.sqlite3"])
    assert {:ok, before_rowid, before_first} = locator_identity(path, message.id)

    message
    |> Message.changeset(%{content: "second searchable value"})
    |> Repo.update!()

    assert {:ok, [{:ok, envelope}]} =
             Corpus.rehydrate_and_authorize("alice", [message.id], local_policy())

    assert {:ok, %{projection_revision: revision}} = Projection.upsert(envelope)
    assert revision > before_first
    assert {:ok, ^before_rowid, ^before_first} = locator_identity(path, message.id)

    assert {:ok, old_query} = Query.parse(%{query: "first"})
    assert {:ok, %{candidates: []}} = Projection.candidates(old_query)
    assert {:ok, new_query} = Query.parse(%{query: "second"})
    assert {:ok, %{candidates: [%{source_id: source_id}]}} = Projection.candidates(new_query)
    assert source_id == message.id

    assert {:ok, _result} = Projection.delete(message.id)
    assert {:ok, %{candidates: []}} = Projection.candidates(new_query)
    assert {:error, :not_found} = locator_identity(path, message.id)
  end

  test "failed rebuild preserves the verified serving generation" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Rollback")
    assert {:ok, message} = local_message(thread, "stable searchable source")
    assert {:ok, build} = Projection.rebuild("alice")

    assert {:ok, _setting} = Settings.put("search.enabled", false)
    assert {:error, :consumer_disabled} = Projection.rebuild("alice")

    assert %{ready?: true, state: "degraded"} = Projection.status()
    assert {:ok, query} = Query.parse(%{query: "stable"})
    assert {:ok, page} = Projection.candidates(query)
    assert page.generation_id == build.generation_id
    assert [%{source_id: source_id}] = page.candidates
    assert source_id == message.id
  end

  test "redaction happens before FTS storage across current and previous generations" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Redaction")
    secret = "sk-ABCDEF1234567890"
    assert {:ok, _message} = local_message(thread, "credential #{secret} must not project")
    assert {:ok, _first} = Projection.rebuild("alice")
    assert {:ok, _second} = Projection.rebuild("alice")

    projection_root = root_for_projection()

    for filename <- ["current.sqlite3", "previous.sqlite3"] do
      bytes = File.read!(Path.join(projection_root, filename))
      refute bytes =~ secret
    end

    assert {:ok, query} = Query.parse(%{query: "redacted"})
    assert {:ok, %{candidates: [_candidate]}} = Projection.candidates(query)
  end

  test "bounded ingestion resumes from per-policy high water and maintenance stays bounded" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Incremental")
    assert {:ok, _initial} = local_message(thread, "initial projection source")
    assert {:ok, _build} = Projection.rebuild("alice")

    for index <- 1..205 do
      assert {:ok, _message} = local_message(thread, "incremental#{index} searchable")
    end

    assert {:ok, first} = Projection.ingest("alice")
    assert first.status == :incomplete
    assert first.indexed_count == 200
    assert first.page_count == 1

    assert {:ok, second} = Projection.ingest("alice")
    assert second.status == :incomplete
    assert second.indexed_count == 5

    assert {:ok, third} = Projection.ingest("alice")
    assert third.status == :complete
    assert third.indexed_count == 0
    refute Projection.status().dirty?

    assert {:ok, query} = Query.parse(%{query: "incremental205"})
    assert {:ok, %{candidates: [%{source_id: source_id}]}} = Projection.candidates(query)
    assert {:ok, %{id: ^source_id}} = Conversations.get_message("alice", source_id)

    assert {:ok, first_maintenance} = Projection.maintain("alice")
    assert first_maintenance.status == :incomplete
    assert first_maintenance.stale_scanned_count == 100

    assert {:ok, second_maintenance} = Projection.maintain("alice")
    assert second_maintenance.status == :incomplete

    assert {:ok, maintenance} = Projection.maintain("alice")
    assert maintenance.status == :complete
    assert maintenance.integrity == :verified
    assert maintenance.merge_pages == 4
  end

  test "hourly ingestion physically reconciles deleted canonical rows in bounded pages" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Stale repair")

    messages =
      for index <- 1..101 do
        assert {:ok, message} = local_message(thread, "stale#{index} searchable")
        message
      end

    assert {:ok, _build} = Projection.rebuild("alice")
    Enum.each(messages, &Repo.delete!/1)

    assert {:ok, first} = Projection.ingest("alice")
    assert first.status == :incomplete
    assert first.stale_scanned_count == 100
    assert first.stale_deleted_count == 100

    assert {:ok, second} = Projection.ingest("alice")
    assert second.status == :complete
    assert second.stale_scanned_count == 1
    assert second.stale_deleted_count == 1

    assert {:ok, query} = Query.parse(%{query: "searchable"})
    assert {:ok, %{candidates: []}} = Projection.candidates(query)
  end

  defp local_message(thread, content) do
    Conversations.append_user_message(thread, content, metadata: %{"channel" => "tui"})
  end

  defp local_policy do
    %{consumer: :search, origin_scope: :local_operator, e2ee?: false}
  end

  defp root_for_projection do
    Projection.status()

    Application.get_env(:allbert_assist, Settings)[:root]
    |> Path.dirname()
    |> Path.join("projection")
  end

  defp locator_identity(path, source_id) do
    with {:ok, conn} <- Exqlite.Sqlite3.open(path, mode: :readonly) do
      try do
        case SQLite.query_one(
               conn,
               "SELECT fts_rowid, first_projected_revision FROM documents WHERE source_id = ?",
               [source_id]
             ) do
          {:ok, [rowid, revision]} -> {:ok, rowid, revision}
          {:error, reason} -> {:error, reason}
        end
      after
        Exqlite.Sqlite3.close(conn)
      end
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
