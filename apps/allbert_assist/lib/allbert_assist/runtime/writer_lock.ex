defmodule AllbertAssist.Runtime.WriterLock do
  @moduledoc """
  Cross-process single-writer guard for the SQLite-backed runtime (v0.62 M3,
  proven in the M0 spike, proof 7).

  A held `BEGIN EXCLUSIVE` transaction on a **sidecar lock database** beside the
  main DB is an OS `fcntl` lock — it is cross-process, auto-released when the
  holding process dies, and a second opener gets `SQLITE_BUSY` immediately.
  This is the guard that stops two BEAM VMs (a packaged daemon + an embedded
  `allbert` command, or two dev runs) from writing one database — the known
  v0.53 failure mode. SQLite's own `busy_timeout` on the main DB is **not** the
  guard: WAL serializes transactions, it does not prevent a second writer.

  `acquire/1` opens the lock DB and holds the exclusive transaction inside a
  spawned holder process for the caller's lifetime; `release/1` (or the
  caller's death) drops it. `held_by_another?/1` is the non-blocking probe used
  by the embedded-fallback path to fail fast with guidance.
  """

  @lock_file "writer.lock.db"

  @typedoc "An opaque handle for a held lock."
  @opaque handle :: %{db: reference(), holder: pid()}

  @doc "The sidecar lock-database path beside the given main DB path."
  @spec lock_path(String.t()) :: String.t()
  def lock_path(db_path) do
    Path.join(Path.dirname(db_path), @lock_file)
  end

  @doc """
  Acquire the exclusive writer lock. Returns `{:ok, handle}` or
  `{:error, :locked}` when another process holds it. The lock is held until
  `release/1` or the calling process exits.
  """
  @spec acquire(String.t()) :: {:ok, handle()} | {:error, term()}
  def acquire(db_path) do
    path = lock_path(db_path)
    File.mkdir_p!(Path.dirname(path))

    with {:ok, db} <- Exqlite.Sqlite3.open(path),
         :ok <- try_begin_exclusive(db) do
      caller = self()

      holder =
        spawn(fn ->
          ref = Process.monitor(caller)

          receive do
            {:release, ^caller} -> :ok
            {:DOWN, ^ref, :process, ^caller, _reason} -> :ok
          end

          Exqlite.Sqlite3.execute(db, "COMMIT")
          Exqlite.Sqlite3.close(db)
        end)

      {:ok, %{db: db, holder: holder}}
    else
      {:error, _reason} = error -> error
    end
  end

  @doc "Release a held lock."
  @spec release(handle()) :: :ok
  def release(%{holder: holder}) do
    send(holder, {:release, self()})
    :ok
  end

  @doc """
  Non-blocking probe: is the writer lock held by another process? Opens the
  lock DB, tries the exclusive transaction, and immediately reports without
  holding anything.
  """
  @spec held_by_another?(String.t()) :: boolean()
  def held_by_another?(db_path) do
    path = lock_path(db_path)

    case Exqlite.Sqlite3.open(path) do
      {:ok, db} ->
        result = try_begin_exclusive(db)
        _ = Exqlite.Sqlite3.execute(db, "ROLLBACK")
        Exqlite.Sqlite3.close(db)
        result != :ok

      _error ->
        false
    end
  end

  defp try_begin_exclusive(db) do
    case Exqlite.Sqlite3.execute(db, "BEGIN EXCLUSIVE") do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
