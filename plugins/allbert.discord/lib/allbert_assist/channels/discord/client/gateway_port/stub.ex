defmodule AllbertAssist.Channels.Discord.Client.GatewayPort.Stub do
  @moduledoc false

  use GenServer

  @behaviour AllbertAssist.Channels.Discord.Client.GatewayPort

  @impl true
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def push(server, event), do: GenServer.call(server, {:push, event})

  @impl true
  def init(opts), do: {:ok, %{owner: Keyword.get(opts, :owner)}}

  @impl true
  def handle_call({:push, event}, _from, state) do
    if is_pid(state.owner), do: send(state.owner, {:discord_gateway_event, event})
    {:reply, :ok, state}
  end
end
