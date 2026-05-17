defmodule AllbertAssist.Objectives.AgentRegistry do
  @moduledoc """
  Minimal registry for future objective delegate agents.

  v0.24 ships the contract empty by default. Specialist agents register in
  later milestones. Dispatch uses `Jido.AgentServer.call/3` so delegate work
  still runs through the Jido runtime instead of becoming a private process
  escape hatch.
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
  def init(state), do: {:ok, state}

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
    if Map.has_key?(state, id) do
      {:reply, {:error, :already_registered}, state}
    else
      entry = %{id: id, server: server, module: module, metadata: metadata}
      {:reply, {:ok, entry}, Map.put(state, id, entry)}
    end
  end

  def handle_call({:unregister, id}, _from, state), do: {:reply, :ok, Map.delete(state, id)}

  def handle_call({:lookup, id}, _from, state) do
    case Map.fetch(state, id) do
      {:ok, entry} -> {:reply, {:ok, entry}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state),
    do: {:reply, state |> Map.values() |> Enum.sort_by(& &1.id), state}
end
