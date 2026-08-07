defmodule AllbertAssist.TestSupport.ReadyEffectContext do
  @moduledoc false

  use GenServer

  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Pack.EffectGuard.TestRegistry

  def context do
    {:ok, barrier} = start_link([])
    {:ok, epoch} = EffectGuard.admit_ready(server: barrier)

    %{allbert_pack_epoch: epoch}
  end

  def attach(context) when is_map(context), do: Map.merge(context, context())

  def server(%{allbert_pack_epoch: epoch}) do
    {:ok, server} = TestRegistry.server(epoch)
    server
  end

  def register(epoch, server), do: TestRegistry.register(epoch, server)

  def replace(server), do: GenServer.call(server, :replace)

  def start_link(opts) do
    owner = Keyword.get(opts, :owner, self())
    GenServer.start_link(__MODULE__, %{owner: owner}, Keyword.drop(opts, [:owner]))
  end

  @impl true
  def init(%{owner: owner}) do
    {:ok,
     %{
       active: spawn(fn -> Process.sleep(:infinity) end),
       replacement: spawn(fn -> Process.sleep(:infinity) end),
       replaced?: false,
       owner_ref: Process.monitor(owner)
     }}
  end

  @impl true
  def handle_call(:status, _from, %{active: active, replacement: replacement} = state) do
    barrier_pid = if state.replaced?, do: replacement, else: active

    {:reply,
     {:ok,
      %{
        phase: :ready,
        barrier_pid: barrier_pid,
        snapshot_digest: String.duplicate("a", 64),
        expected_ids: [],
        subscribed_ids: [],
        acked_ids: [],
        diagnostics: []
      }}, state}
  end

  def handle_call(:replace, _from, state), do: {:reply, :ok, %{state | replaced?: true}}

  @impl true
  def handle_info({:DOWN, owner_ref, :process, _owner, _reason}, %{owner_ref: owner_ref} = state),
    do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, %{active: active, replacement: replacement}) do
    Process.exit(active, :kill)
    Process.exit(replacement, :kill)
  end
end
