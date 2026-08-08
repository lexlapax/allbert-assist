defmodule AllbertAssist.Kernel.Contract.Owner do
  @moduledoc """
  Lifecycle owner for the sealed contract binding.

  `AllbertAssist.Kernel.Contract` validates and publishes; this process decides
  how long a publication lives. It is a plain GenServer: it owns one monitor and
  one atomic publication, and performs no model reasoning, Skill composition,
  permission decision, or pack effect.

  Composition binds through here rather than through the binder directly so that
  the binding cannot outlive the readiness barrier it was bound against. The
  owner monitors that barrier and releases the whole set when it goes down, and
  releases again on its own termination. That is how provider loss is expressed:
  the contracts are deleted, every kernel concern falls to its fail-closed
  result, and the next composition binds a fresh generation. Nothing is retained
  to answer from.

  It shares the Pack restart epoch, so a coordinator or barrier restart tears
  the binding down with the registry snapshot that produced it.
  """

  use GenServer

  alias AllbertAssist.Kernel.Contract
  alias AllbertAssist.Kernel.Contract.Binding

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Validate and publish `providers` for one generation and barrier.

  Returns the binder's own error unchanged when the set is rejected, so
  composition fails on the specific reason rather than a generic one.
  """
  @spec bind(GenServer.server(), [term()], String.t(), pid()) ::
          {:ok, Binding.t()} | {:error, term()}
  def bind(server \\ __MODULE__, providers, generation, barrier_pid) do
    GenServer.call(server, {:bind, providers, generation, barrier_pid})
  end

  @doc "Release the current binding, if any."
  @spec release(GenServer.server()) :: :ok
  def release(server \\ __MODULE__), do: GenServer.call(server, :release)

  @doc "The generation this owner currently holds, or `{:error, :unbound}`."
  @spec generation(GenServer.server()) :: {:ok, String.t()} | {:error, :unbound}
  def generation(server \\ __MODULE__), do: GenServer.call(server, :generation)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    # A previous epoch's publication must not survive this one's start.
    Contract.release()
    {:ok, %{monitor: nil}}
  end

  @impl true
  def handle_call({:bind, providers, generation, barrier_pid}, _from, state) do
    case Contract.bind(providers, generation, barrier_pid) do
      {:ok, binding} ->
        {:reply, {:ok, binding}, %{state | monitor: remonitor(state.monitor, barrier_pid)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:release, _from, state) do
    Contract.release()
    {:reply, :ok, %{state | monitor: demonitor(state.monitor)}}
  end

  def handle_call(:generation, _from, state), do: {:reply, Contract.generation(), state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state) do
    Contract.release()
    {:noreply, %{state | monitor: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    Contract.release()
    :ok
  end

  defp remonitor(previous, barrier_pid) do
    demonitor(previous)
    Process.monitor(barrier_pid)
  end

  defp demonitor(nil), do: nil

  defp demonitor(ref) do
    Process.demonitor(ref, [:flush])
    nil
  end
end
