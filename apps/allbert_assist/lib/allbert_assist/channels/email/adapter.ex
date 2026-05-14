defmodule AllbertAssist.Channels.Email.Adapter do
  @moduledoc false

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def poll_once(server \\ __MODULE__), do: GenServer.call(server, :poll_once)

  @impl true
  def init(_opts) do
    {:ok, %{enabled: false, diagnostics: [:not_implemented]}}
  end

  @impl true
  def handle_call(:poll_once, _from, state) do
    {:reply, {:error, :disabled}, state}
  end
end
