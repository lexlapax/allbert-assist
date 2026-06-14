defmodule AllbertAssist.Settings.Supervisor do
  @moduledoc """
  Supervisor for Settings Central runtime processes.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    children = [
      {AllbertAssist.Settings.KeyCustody, Keyword.get(opts, :key_custody, [])}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
