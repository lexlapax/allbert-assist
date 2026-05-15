defmodule AllbertAssist.Plugin.Supervisor do
  @moduledoc false

  use Supervisor

  alias AllbertAssist.Plugin.Bootstrap
  alias AllbertAssist.Plugin.ChildSupervisor
  alias AllbertAssist.Plugin.Registry

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    registry_opts = Keyword.get(opts, :registry_opts, opts)
    child_supervisor = Keyword.get(opts, :child_supervisor, ChildSupervisor)
    registry = Keyword.get(registry_opts, :name, Registry)

    children = [
      {Registry, registry_opts},
      {ChildSupervisor, [name: child_supervisor]},
      {Bootstrap,
       opts
       |> Keyword.put(:registry, registry)
       |> Keyword.put(:child_supervisor, child_supervisor)}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
