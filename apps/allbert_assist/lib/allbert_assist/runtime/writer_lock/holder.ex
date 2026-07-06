defmodule AllbertAssist.Runtime.WriterLock.Holder do
  @moduledoc """
  Supervised holder of the single-writer lock (v0.62 M5). Added to the
  supervision tree **only** in daemon/serve mode (`ALLBERT_HOLD_WRITER_LOCK`
  set by the `serve` launcher), so `allbert serve` owns the database writer
  lock for its lifetime. A second `allbert` command should attach to the daemon
  first; if attach is unavailable, `WriterLock.held_by_another?/1` refuses the
  embedded fallback instead of booting a competing writer (Locked Decision 5).
  Dev/test starts do not hold the lock, so concurrent test runs are unaffected
  — the guard is a daemon-coexistence protection, not a test constraint.
  """
  use GenServer

  require Logger

  alias AllbertAssist.Runtime.WriterLock

  @doc "True when this start should hold the writer lock (serve/daemon mode)."
  @spec enabled?() :: boolean()
  def enabled? do
    System.get_env("ALLBERT_HOLD_WRITER_LOCK") in ["1", "true"]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    db = AllbertAssist.Database.repo_database_path()

    case db && WriterLock.acquire(db) do
      {:ok, handle} ->
        Logger.info("writer lock acquired (serve/daemon single-writer guard)")
        {:ok, %{handle: handle, db: db}}

      {:error, reason} ->
        {:stop, {:writer_lock_unavailable, reason}}

      nil ->
        {:ok, %{handle: nil, db: nil}}
    end
  end

  @impl true
  def terminate(_reason, %{handle: handle}) when not is_nil(handle) do
    WriterLock.release(handle)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
