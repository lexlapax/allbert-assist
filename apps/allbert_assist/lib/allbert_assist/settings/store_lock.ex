defmodule AllbertAssist.Settings.StoreLock do
  @moduledoc """
  A short-lived, cross-process transaction lock for Settings writes.

  The sidecar SQLite database supplies an OS-backed exclusive lock shared by
  every BEAM using one Allbert Home. Unlike the runtime writer lock, this lock
  is acquired only around one settings read/validate/write transaction.
  """

  @lock_file "settings.lock.db"
  @retry_ms 50
  @timeout_ms 5_000

  @spec with_lock(String.t(), (-> result)) :: result | {:error, term()} when result: term()
  def with_lock(settings_root, fun) when is_binary(settings_root) and is_function(fun, 0) do
    path = Path.join(settings_root, @lock_file)
    File.mkdir_p!(settings_root)
    deadline = System.monotonic_time(:millisecond) + @timeout_ms

    with {:ok, db} <- acquire(path, deadline) do
      try do
        fun.()
      after
        _ = Exqlite.Sqlite3.execute(db, "COMMIT")
        _ = Exqlite.Sqlite3.close(db)
      end
    end
  end

  defp acquire(path, deadline) do
    case Exqlite.Sqlite3.open(path) do
      {:ok, db} -> begin_exclusive(db, path, deadline)
      {:error, _reason} = error -> error
    end
  end

  defp begin_exclusive(db, path, deadline) do
    case Exqlite.Sqlite3.execute(db, "BEGIN EXCLUSIVE") do
      :ok ->
        {:ok, db}

      {:error, reason} ->
        _ = Exqlite.Sqlite3.close(db)
        retry_or_timeout(path, deadline, reason)
    end
  end

  defp retry_or_timeout(path, deadline, reason) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(@retry_ms)
      acquire(path, deadline)
    else
      {:error, {:settings_lock_timeout, reason}}
    end
  end
end
