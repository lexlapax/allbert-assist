defmodule AllbertAssist.Objectives.AgentRegistry do
  @moduledoc """
  Minimal monitored registry for future objective delegate agents.

  v0.24 ships the contract empty by default. Specialist agents register in
  later milestones. Dispatch uses `Jido.AgentServer.call/3` so delegate work
  still runs through the Jido runtime instead of becoming a private process
  escape hatch.

  This is a small GenServer rather than a global Jido registry integration
  because v0.24 only needs one local objective-agent namespace. Entries are
  monitored and evicted when their process exits, which keeps v0.25 specialist
  agents from dispatching to dead pids while leaving room to swap in a
  Jido-native registry once Allbert needs distributed discovery.
  """

  use GenServer

  alias Jido.AgentServer
  alias Jido.Signal

  @type entry :: %{id: String.t(), server: GenServer.server(), module: module(), metadata: map()}

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  @impl true
  def init(_state), do: {:ok, %{entries: %{}, refs: %{}}}

  @spec register(String.t(), GenServer.server(), module(), map()) ::
          {:ok, entry()} | {:error, :already_registered}
  def register(id, server, module, metadata \\ %{}) when is_binary(id) and is_atom(module) do
    GenServer.call(__MODULE__, {:register, id, server, module, metadata})
  end

  @spec unregister(String.t()) :: :ok
  def unregister(id) when is_binary(id), do: GenServer.call(__MODULE__, {:unregister, id})

  @spec lookup(String.t()) :: {:ok, entry()} | {:error, :not_found}
  def lookup(id) when is_binary(id), do: GenServer.call(__MODULE__, {:lookup, id})

  @spec list() :: [entry()]
  def list, do: GenServer.call(__MODULE__, :list)

  @spec dispatch(String.t(), atom(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def dispatch(agent_id, command, params, opts \\ [])
      when is_binary(agent_id) and is_atom(command) and is_map(params) do
    with {:ok, entry} <- lookup(agent_id),
         {:ok, signal} <-
           Signal.new("allbert.objectives.delegate.#{command}", params,
             source: "/allbert/objectives/delegate/#{agent_id}"
           ),
         {:ok, agent} <-
           AgentServer.call(entry.server, signal, Keyword.get(opts, :timeout, 5_000)) do
      {:ok, %{agent_id: agent_id, state: agent.state}}
    end
  end

  @impl true
  def handle_call({:register, id, server, module, metadata}, _from, state) do
    cond do
      Map.has_key?(state.entries, id) ->
        {:reply, {:error, :already_registered}, state}

      is_nil(server_pid(server)) ->
        {:reply, {:error, :server_not_found}, state}

      true ->
        ref = server |> server_pid() |> Process.monitor()
        entry = %{id: id, server: server, module: module, metadata: metadata}

        state =
          state
          |> put_in([:entries, id], Map.put(entry, :monitor_ref, ref))
          |> put_in([:refs, ref], id)

        {:reply, {:ok, entry}, state}
    end
  end

  def handle_call({:unregister, id}, _from, state) do
    {:reply, :ok, remove_entry(state, id)}
  end

  def handle_call({:lookup, id}, _from, state) do
    case Map.fetch(state.entries, id) do
      {:ok, entry} ->
        if alive_entry?(entry) do
          {:reply, {:ok, public_entry(entry)}, state}
        else
          {:reply, {:error, :not_found}, remove_entry(state, id)}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state) do
    {entries, state} =
      state.entries
      |> Map.keys()
      |> Enum.reduce({[], state}, &collect_live_entry/2)

    {:reply, Enum.sort_by(entries, & &1.id), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {id, refs} ->
        {:noreply, %{state | entries: Map.delete(state.entries, id), refs: refs}}
    end
  end

  defp alive_entry?(%{server: server}) do
    case server_pid(server) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _other -> false
    end
  end

  defp collect_live_entry(id, {entries, state}) do
    with {:ok, entry} <- Map.fetch(state.entries, id),
         true <- alive_entry?(entry) do
      {[public_entry(entry) | entries], state}
    else
      false -> {entries, remove_entry(state, id)}
      :error -> {entries, state}
    end
  end

  defp server_pid(pid) when is_pid(pid), do: if(Process.alive?(pid), do: pid)
  defp server_pid(name) when is_atom(name), do: Process.whereis(name)

  defp server_pid({:global, name}) do
    case :global.whereis_name(name) do
      :undefined -> nil
      pid -> pid
    end
  end

  defp server_pid({:via, module, term}) do
    case module.whereis_name(term) do
      :undefined -> nil
      nil -> nil
      pid -> pid
    end
  end

  defp server_pid(_server), do: nil

  defp remove_entry(state, id) do
    case Map.pop(state.entries, id) do
      {nil, _entries} ->
        state

      {%{monitor_ref: ref}, entries} ->
        Process.demonitor(ref, [:flush])
        %{state | entries: entries, refs: Map.delete(state.refs, ref)}
    end
  end

  defp public_entry(entry), do: Map.delete(entry, :monitor_ref)
end
