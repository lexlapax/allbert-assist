defmodule AllbertAssist.Jobs.Scheduler do
  @moduledoc """
  Public facade for the scheduled-job runtime.

  Since v0.23, calls delegate to `AllbertAssist.Jobs.Scheduler.Agent`, a
  JidoBacked coordinator. Job and run rows in SQLite remain authoritative; the
  agent keeps only runtime configuration and diagnostics.
  """

  alias AllbertAssist.Jobs.Scheduler.Agent
  alias AllbertAssist.Jobs.Scheduler.Executor

  @doc "Start the scheduler agent."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)

    opts
    |> Keyword.put_new(:id, scheduler_id(Keyword.fetch!(opts, :name)))
    |> Agent.start_link()
  end

  @doc "Run one scheduler polling cycle synchronously."
  @spec run_once(GenServer.server(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def run_once(server \\ __MODULE__, now \\ Executor.utc_now()) do
    Agent.run_once(server, now)
  end

  @doc "Fail stale running rows synchronously."
  @spec cleanup_stale_runs(GenServer.server(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_stale_runs(server \\ __MODULE__, now \\ Executor.utc_now()) do
    Agent.cleanup_stale_runs(server, now)
  end

  defp scheduler_id(name) when is_atom(name), do: Atom.to_string(name)
  defp scheduler_id(name), do: inspect(name)
end
