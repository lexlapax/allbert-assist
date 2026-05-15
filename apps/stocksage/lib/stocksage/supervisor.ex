defmodule StockSage.Supervisor do
  @moduledoc """
  StockSage plugin supervisor placeholder.

  v0.20 has no long-running StockSage workers. Later milestones add the bridge
  and native analysis workers under this supervisor instead of starting them
  outside the plugin lifecycle.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
end
