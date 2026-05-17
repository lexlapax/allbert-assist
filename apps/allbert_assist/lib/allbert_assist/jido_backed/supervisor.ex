defmodule AllbertAssist.JidoBacked.Supervisor do
  @moduledoc """
  Supervisor for core JidoBacked coordinators.

  v0.23 starts the confirmation store and scheduled-job scheduler agents here
  so converted coordinators have one shared supervision point. Later
  milestones can append additional JidoBacked coordinators with
  `:extra_children` without replacing the v0.23 children.
  """

  use Supervisor

  @doc false
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    children = configured_children(opts)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp configured_children(opts) do
    case Keyword.fetch(opts, :children) do
      {:ok, children} ->
        children

      :error ->
        default_children(opts) ++ Keyword.get(opts, :extra_children, [])
    end
    |> Enum.reject(&is_nil/1)
  end

  defp default_children(opts) do
    confirmations_opts =
      opts
      |> Keyword.get(:confirmations, [])
      |> Keyword.put_new(:name, AllbertAssist.Confirmations.Store.Agent)

    scheduler_opts =
      opts
      |> Keyword.get(:scheduler, [])
      |> Keyword.put_new(:name, AllbertAssist.Jobs.Scheduler)

    [
      {AllbertAssist.Confirmations.Store.Agent, confirmations_opts},
      {AllbertAssist.Jobs.Scheduler.Agent, scheduler_opts}
    ]
  end
end
