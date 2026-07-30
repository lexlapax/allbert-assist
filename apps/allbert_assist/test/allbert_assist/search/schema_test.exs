defmodule AllbertAssist.Search.SchemaTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Search.Schema
  alias AllbertAssist.Search.SQLite
  alias Exqlite.Sqlite3

  test "loaded Exqlite SQLite proves the schema-1 FTS capability contract" do
    assert {:ok, conn} = Sqlite3.open(":memory:")

    on_exit(fn -> Sqlite3.close(conn) end)

    generation_id = "019fb383-4a88-7000-8000-000000000001"

    assert :ok =
             Schema.create(conn, %{
               generation_id: generation_id,
               eligibility_epoch: 0,
               high_water: nil
             })

    assert {:ok, capability} = Schema.verify(conn, generation_id)
    assert capability.fts5
    assert capability.schema_version == 1

    assert :ok =
             SQLite.write(
               conn,
               "INSERT INTO documents(fts_rowid, source_type, source_id, thread_id, author, " <>
                 "trust, surface, thread_kind, origin_scope, e2ee, timestamp_us, source_version, " <>
                 "content_digest, redactor_version, tokenizer_version, schema_version, " <>
                 "first_projected_revision) VALUES(1, 'conversation', 'm1', 't1', 'operator', " <>
                 "'private_operator', 'tui', 'general', 'local_operator', 0, 1, 1, 'sha256:x', 1, 1, 1, 1)"
             )

    assert :ok =
             SQLite.write(conn, "INSERT INTO search_fts(rowid, searchable_text) VALUES(1, ?)", [
               "hello café"
             ])

    assert {:ok, _capability} = Schema.verify(conn, generation_id)
  end

  test "bijection verification rejects a missing FTS row" do
    assert {:ok, conn} = Sqlite3.open(":memory:")
    on_exit(fn -> Sqlite3.close(conn) end)

    assert :ok =
             Schema.create(conn, %{
               generation_id: "019fb383-4a88-7000-8000-000000000002",
               eligibility_epoch: 0,
               high_water: nil
             })

    assert :ok =
             SQLite.write(
               conn,
               "INSERT INTO documents(fts_rowid, source_type, source_id, thread_id, author, " <>
                 "trust, surface, thread_kind, origin_scope, e2ee, timestamp_us, source_version, " <>
                 "content_digest, redactor_version, tokenizer_version, schema_version, " <>
                 "first_projected_revision) VALUES(1, 'conversation', 'm1', 't1', 'operator', " <>
                 "'private_operator', 'tui', 'general', 'local_operator', 0, 1, 1, 'sha256:x', 1, 1, 1, 1)"
             )

    assert {:error, {:search_integrity_failed, [1]}} = Schema.verify(conn)
  end
end
