defmodule AllbertAssist.FirstRun.Enablement.Latch do
  @moduledoc false

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :pending, name: name)
  end

  @spec completed?(GenServer.server()) :: boolean()
  def completed?(server \\ __MODULE__), do: GenServer.call(server, :completed?)

  @spec complete(GenServer.server()) :: :ok
  def complete(server \\ __MODULE__), do: GenServer.call(server, :complete)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:completed?, _from, state), do: {:reply, state == :complete, state}

  def handle_call(:complete, _from, _state), do: {:reply, :ok, :complete}
end
