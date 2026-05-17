defmodule AllbertAssist.Jobs.Scheduler.Legacy do
  @moduledoc """
  Transitional v0.22 scheduler process preserved for v0.23 parity tests.

  This module is deleted during the v0.23 legacy-removal milestone.
  """

  use GenServer

  alias AllbertAssist.Jobs.Scheduler.Executor

  defstruct [
    :interval_ms,
    :initial_delay_ms,
    :batch_size,
    :stale_run_ms,
    :enabled?,
    :poll_on_start?,
    :cleanup_on_start?
  ]

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def run_once(server \\ __MODULE__, now \\ Executor.utc_now()) do
    GenServer.call(server, {:run_once, now}, :infinity)
  end

  @doc false
  def cleanup_stale_runs(server \\ __MODULE__, now \\ Executor.utc_now()) do
    GenServer.call(server, {:cleanup_stale_runs, now}, :infinity)
  end

  @impl true
  def init(opts) do
    state = struct!(__MODULE__, Map.take(Executor.build_state(opts), struct_keys()))

    if state.cleanup_on_start? do
      Executor.cleanup_stale_runs_for_state(state, Executor.utc_now())
    end

    if state.enabled? and state.poll_on_start? do
      Process.send_after(self(), :tick, state.initial_delay_ms)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:run_once, now}, _from, state) do
    {:reply, Executor.poll_once(state, now), state}
  end

  def handle_call({:cleanup_stale_runs, now}, _from, state) do
    {:reply, Executor.cleanup_stale_runs_for_state(state, now), state}
  end

  @impl true
  def handle_info(:tick, state) do
    _summary = Executor.poll_once(state, Executor.utc_now())

    if state.enabled? do
      Process.send_after(self(), :tick, state.interval_ms)
    end

    {:noreply, state}
  end

  defp struct_keys do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
