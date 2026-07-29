defmodule AllbertAssist.Projection.PromoteProtocolTest do
  use ExUnit.Case, async: false

  @moduletag :home_fs_serial

  alias AllbertAssist.Projection.PromoteProtocol
  alias Exqlite.Sqlite3

  @generation_id "018f3f4a-8b2c-7def-8abc-0123456789ab"

  setup do
    root = temp_path("projection")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "checkpointed builder promotes to current and retains the prior generation", %{root: root} do
    current_path = Path.join(root, "current.sqlite3")
    builder_path = Path.join(root, "build-#{@generation_id}.sqlite3")
    {:ok, serving_conn} = database(current_path, "old")
    {:ok, builder_conn} = database(builder_path, "new")
    parent = self()

    assert {:ok, promoted} =
             PromoteProtocol.promote(
               root: root,
               generation_id: @generation_id,
               builder_conn: builder_conn,
               serving_conn: serving_conn,
               verify: &verify_generation/2,
               quiesce: fn ->
                 send(parent, :quiesced)
                 :ok
               end
             )

    assert_received :quiesced
    assert promoted.builder_conn == nil
    assert {:ok, "new"} = generation(promoted.serving_conn)
    assert {:ok, previous_conn} = Sqlite3.open(promoted.previous_path, mode: :readonly)
    assert {:ok, "old"} = generation(previous_conn)
    assert :ok = Sqlite3.close(previous_conn)
    refute File.exists?(builder_path)
    refute File.exists?(builder_path <> "-wal")
    refute File.exists?(builder_path <> "-shm")
    assert :ok = Sqlite3.close(promoted.serving_conn)
  end

  test "busy checkpoint does not quiesce or close either live handle", %{root: root} do
    current_path = Path.join(root, "current.sqlite3")
    builder_path = Path.join(root, "build-#{@generation_id}.sqlite3")
    {:ok, serving_conn} = database(current_path, "old")
    {:ok, builder_conn} = database(builder_path, "new")
    {:ok, reader_conn} = Sqlite3.open(builder_path, mode: :readonly)
    assert :ok = Sqlite3.execute(reader_conn, "BEGIN")
    assert {:ok, "new"} = generation(reader_conn)
    assert :ok = Sqlite3.execute(builder_conn, "INSERT INTO events(value) VALUES ('held')")
    parent = self()

    assert {:error, {:checkpoint_busy, busy}, retained} =
             PromoteProtocol.promote(
               root: root,
               generation_id: @generation_id,
               builder_conn: builder_conn,
               serving_conn: serving_conn,
               verify: &verify_generation/2,
               quiesce: fn ->
                 send(parent, :unexpected_quiesce)
                 :ok
               end
             )

    assert busy > 0
    refute_received :unexpected_quiesce
    assert retained.builder_conn == builder_conn
    assert retained.serving_conn == serving_conn
    assert {:ok, "old"} = generation(serving_conn)
    assert :ok = Sqlite3.execute(reader_conn, "ROLLBACK")
    assert :ok = Sqlite3.close(reader_conn)
    assert :ok = Sqlite3.close(builder_conn)
    assert :ok = Sqlite3.close(serving_conn)
  end

  test "self-contained proof failure preserves current and never quiesces", %{root: root} do
    current_path = Path.join(root, "current.sqlite3")
    builder_path = Path.join(root, "build-#{@generation_id}.sqlite3")
    {:ok, serving_conn} = database(current_path, "old")
    {:ok, builder_conn} = database(builder_path, "new")
    parent = self()

    assert {:error, :builder_manifest_invalid, retained} =
             PromoteProtocol.promote(
               root: root,
               generation_id: @generation_id,
               builder_conn: builder_conn,
               serving_conn: serving_conn,
               verify: fn conn, _path ->
                 case generation(conn) do
                   {:ok, "new"} -> {:error, :builder_manifest_invalid}
                   {:ok, _other} -> :ok
                 end
               end,
               quiesce: fn ->
                 send(parent, :unexpected_quiesce)
                 :ok
               end
             )

    refute_received :unexpected_quiesce
    assert retained.builder_conn == nil
    assert retained.serving_conn == serving_conn
    assert {:ok, "old"} = generation(serving_conn)
    assert File.exists?(builder_path)
    assert :ok = Sqlite3.close(serving_conn)
  end

  test "failed verified reopen rolls back to the prior current", %{root: root} do
    current_path = Path.join(root, "current.sqlite3")
    builder_path = Path.join(root, "build-#{@generation_id}.sqlite3")
    {:ok, serving_conn} = database(current_path, "old")
    {:ok, builder_conn} = database(builder_path, "new")

    verifier = fn conn, path ->
      case {Path.basename(path), generation(conn)} do
        {"current.sqlite3", {:ok, "new"}} -> {:error, :promoted_manifest_invalid}
        {_path, {:ok, _generation}} -> :ok
      end
    end

    assert {:error, :promoted_manifest_invalid, restored} =
             PromoteProtocol.promote(
               root: root,
               generation_id: @generation_id,
               builder_conn: builder_conn,
               serving_conn: serving_conn,
               verify: verifier,
               quiesce: fn -> :ok end
             )

    assert {:ok, "old"} = generation(restored.serving_conn)
    assert File.exists?(builder_path)
    refute File.exists?(restored.previous_path)
    assert :ok = Sqlite3.close(restored.serving_conn)
  end

  test "fixed UUIDv7 builder naming rejects an arbitrary path contract", %{root: root} do
    path = Path.join(root, "build-not-a-generation.sqlite3")
    {:ok, builder_conn} = database(path, "new")

    assert {:error, :invalid_generation_id, state} =
             PromoteProtocol.promote(
               root: root,
               generation_id: "../not-a-generation",
               builder_conn: builder_conn,
               serving_conn: nil,
               verify: &verify_generation/2,
               quiesce: fn -> :ok end
             )

    assert state.current_path == ""
    assert {:ok, "new"} = generation(builder_conn)
    assert :ok = Sqlite3.close(builder_conn)
  end

  defp database(path, generation) do
    with {:ok, conn} <- Sqlite3.open(path),
         :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode=WAL"),
         :ok <-
           Sqlite3.execute(
             conn,
             "CREATE TABLE generation_meta (generation_id TEXT NOT NULL);" <>
               "CREATE TABLE events (value TEXT NOT NULL);" <>
               "INSERT INTO generation_meta(generation_id) VALUES ('#{generation}')"
           ) do
      {:ok, conn}
    end
  end

  defp verify_generation(conn, _path) do
    case generation(conn) do
      {:ok, value} when is_binary(value) -> :ok
      _other -> {:error, :generation_manifest_invalid}
    end
  end

  defp generation(conn) do
    query_one(conn, "SELECT generation_id FROM generation_meta LIMIT 1")
    |> case do
      {:ok, [value]} -> {:ok, value}
      other -> other
    end
  end

  defp query_one(conn, sql) do
    with {:ok, statement} <- Sqlite3.prepare(conn, sql) do
      try do
        case Sqlite3.step(conn, statement) do
          {:row, row} -> {:ok, row}
          other -> {:error, other}
        end
      after
        :ok = Sqlite3.release(conn, statement)
      end
    end
  end

  defp temp_path(suffix) do
    Path.join(
      System.tmp_dir!(),
      "allbert-promote-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end
end
