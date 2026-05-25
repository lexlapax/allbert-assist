defmodule AllbertAssist.DynamicPlugins.Reconciler do
  @moduledoc """
  One-shot boot reconciliation for dynamic integration metadata.

  Plain GenServer is used only to sequence the post-start reconciliation after
  the overlay process exists. It stores the latest bounded result for
  observability; durable authority still lives in Allbert Home metadata.
  """

  use GenServer

  alias AllbertAssist.DynamicPlugins.Loader

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Return the last reconciliation result recorded by this node."
  def last_result(server \\ __MODULE__) do
    case Process.whereis(server) do
      nil -> nil
      _pid -> GenServer.call(server, :last_result)
    end
  end

  @impl true
  def init(_opts) do
    send(self(), :reconcile)
    {:ok, %{last_result: nil}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    result = Loader.reconcile()
    {:noreply, %{state | last_result: result}}
  end

  @impl true
  def handle_call(:last_result, _from, state) do
    {:reply, state.last_result, state}
  end
end
