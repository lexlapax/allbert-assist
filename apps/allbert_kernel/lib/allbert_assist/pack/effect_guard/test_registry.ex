if Mix.env() == :test do
  defmodule AllbertAssist.Pack.EffectGuard.TestRegistry do
    @moduledoc false

    use GenServer

    @spec register(AllbertAssist.Pack.EffectGuard.epoch(), GenServer.server(), pid()) :: :ok
    def register(epoch, server, owner \\ self())
        when is_map(epoch) and is_pid(server) and is_pid(owner) do
      GenServer.call(ensure_started(), {:register, epoch, server, owner})
    end

    @spec server(AllbertAssist.Pack.EffectGuard.epoch()) :: {:ok, GenServer.server()} | :error
    def server(epoch) when is_map(epoch) do
      case Process.whereis(__MODULE__) do
        nil -> :error
        registry -> GenServer.call(registry, {:server, epoch})
      end
    end

    defp ensure_started do
      case Process.whereis(__MODULE__) do
        nil ->
          case GenServer.start(__MODULE__, %{}, name: __MODULE__) do
            {:ok, registry} -> registry
            {:error, {:already_started, registry}} -> registry
          end

        registry ->
          registry
      end
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:register, epoch, server, owner}, _from, state) do
      case Map.get(state, epoch) do
        {_old_server, old_owner_ref} -> Process.demonitor(old_owner_ref, [:flush])
        nil -> :ok
      end

      owner_ref = Process.monitor(owner)
      state = Map.put(state, epoch, {server, owner_ref})
      {:reply, :ok, state, state_timeout(state)}
    end

    def handle_call({:server, epoch}, _from, state) do
      reply =
        case Map.get(state, epoch) do
          {server, _owner_ref} when is_pid(server) -> {:ok, server}
          _other -> :error
        end

      {:reply, reply, state, state_timeout(state)}
    end

    @impl true
    def handle_info({:DOWN, owner_ref, :process, _owner, _reason}, state) do
      state =
        Map.reject(state, fn {_epoch, {_server, registered_ref}} ->
          registered_ref == owner_ref
        end)

      {:noreply, state, state_timeout(state)}
    end

    @impl true
    def handle_info(:timeout, state) when map_size(state) == 0, do: {:stop, :normal, state}
    def handle_info(:timeout, state), do: {:noreply, state, :infinity}

    defp state_timeout(state) when map_size(state) == 0, do: 5_000
    defp state_timeout(_state), do: :infinity
  end
end
