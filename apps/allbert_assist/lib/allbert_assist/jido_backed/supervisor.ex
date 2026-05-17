defmodule AllbertAssist.JidoBacked.Supervisor do
  @moduledoc """
  Supervisor for core JidoBacked coordinators.

  v0.23 starts the confirmation store agent here first. The scheduler agent is
  added in the scheduler conversion milestone so there is never a double-started
  scheduler process.
  """

  use Supervisor

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children =
      opts
      |> Keyword.get(:children, default_children(opts))
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp default_children(opts) do
    confirmations_opts =
      opts
      |> Keyword.get(:confirmations, [])
      |> Keyword.put_new(:name, AllbertAssist.Confirmations.Store.Agent)

    [{AllbertAssist.Confirmations.Store.Agent, confirmations_opts}]
  end
end
