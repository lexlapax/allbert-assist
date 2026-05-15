defmodule AllbertAssist.Channels.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Supervisor.init(AllbertAssist.Channels.channel_child_specs(opts), strategy: :one_for_one)
  end
end
