defmodule AllbertAssist.Plugin.MetadataSupervisor do
  @moduledoc false

  use Supervisor

  alias AllbertAssist.Plugin.Bootstrap
  alias AllbertAssist.Plugin.Registry

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Supervisor.start_link(__MODULE__, opts)
      name -> Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    registry_opts = Keyword.get(opts, :registry_opts, Keyword.delete(opts, :name))
    registry = Keyword.get(registry_opts, :name, Registry)
    bootstrap = Keyword.get(opts, :bootstrap, Bootstrap)

    children = [
      {Registry, registry_opts},
      {Bootstrap,
       opts
       |> Keyword.put(:registry, registry)
       |> Keyword.put(:name, bootstrap)
       |> Keyword.put(:metadata_only?, true)}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
