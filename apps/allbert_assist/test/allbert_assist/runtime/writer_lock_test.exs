defmodule AllbertAssist.Runtime.WriterLockTest do
  @moduledoc """
  v0.62 M3 — the single-writer guard (proven in the M0 spike, proof 7): a held
  `BEGIN EXCLUSIVE` on the sidecar lock DB refuses a second acquirer and the
  non-blocking probe reports it, so the embedded-fallback path fails fast with
  guidance instead of corrupting the database.
  """
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.Runtime.WriterLock

  setup do
    dir = Path.join(System.tmp_dir!(), "writerlock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    db = Path.join(dir, "allbert.sqlite3")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, db: db}
  end

  test "acquire holds the lock; a second acquire is refused", %{db: db} do
    assert {:ok, handle} = WriterLock.acquire(db)
    assert {:error, _busy} = WriterLock.acquire(db)

    :ok = WriterLock.release(handle)
    # Give the holder process a moment to COMMIT + close.
    Process.sleep(50)
    assert {:ok, handle2} = WriterLock.acquire(db)
    :ok = WriterLock.release(handle2)
  end

  test "held_by_another? probes without holding", %{db: db} do
    refute WriterLock.held_by_another?(db)

    {:ok, handle} = WriterLock.acquire(db)
    assert WriterLock.held_by_another?(db)

    :ok = WriterLock.release(handle)
    Process.sleep(50)
    refute WriterLock.held_by_another?(db)
  end

  test "the lock is released when the holding process dies", %{db: db} do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _handle} = WriterLock.acquire(db)
        send(parent, :acquired)
        Process.sleep(:infinity)
      end)

    assert_receive :acquired, 1_000
    assert WriterLock.held_by_another?(db)

    Process.exit(pid, :kill)
    Process.sleep(100)
    # Auto-released on process death (fcntl semantics).
    refute WriterLock.held_by_another?(db)
  end

  test "lock_path is a sidecar beside the main DB", %{db: db} do
    assert WriterLock.lock_path(db) == Path.join(Path.dirname(db), "writer.lock.db")
  end
end
