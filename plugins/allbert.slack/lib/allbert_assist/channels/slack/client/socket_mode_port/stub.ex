defmodule AllbertAssist.Channels.Slack.Client.SocketModePort.Stub do
  @moduledoc false

  use GenServer

  @behaviour AllbertAssist.Channels.Slack.Client.SocketModePort

  @impl true
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def push(server, envelope), do: GenServer.call(server, {:push, envelope})

  @impl true
  def ack(server, envelope_id, payload \\ nil) do
    GenServer.call(server, {:ack, envelope_id, payload})
  end

  @impl true
  def init(opts), do: {:ok, %{owner: Keyword.get(opts, :owner), acks: []}}

  @impl true
  def handle_call({:push, envelope}, _from, state) do
    if is_pid(state.owner), do: send(state.owner, {:slack_socket_envelope, envelope})
    {:reply, :ok, state}
  end

  def handle_call({:ack, envelope_id, payload}, _from, state) do
    ack = %{"envelope_id" => envelope_id} |> maybe_put("payload", payload)
    if is_pid(state.owner), do: send(state.owner, {:slack_socket_ack, ack})
    {:reply, :ok, %{state | acks: state.acks ++ [ack]}}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
