defmodule AllbertAssist.App.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    registry = Keyword.get(opts, :registry, AllbertAssist.App.Registry)

    dynamic_supervisor =
      Keyword.get(opts, :dynamic_supervisor, AllbertAssist.App.DynamicSupervisor)

    bootstrap = Keyword.get(opts, :bootstrap, AllbertAssist.App.Bootstrap)
    plugin_registry = Keyword.get(opts, :plugin_registry, AllbertAssist.Plugin.Registry)
    table_name = Keyword.get(opts, :table_name, :allbert_app_registry)
    enabled? = Keyword.get(opts, :enabled?, true)

    children = [
      {AllbertAssist.App.Registry,
       name: registry,
       table_name: table_name,
       enabled?: enabled?,
       dynamic_supervisor: dynamic_supervisor},
      {AllbertAssist.App.DynamicSupervisor, name: dynamic_supervisor},
      {AllbertAssist.App.Bootstrap,
       name: bootstrap, registry: registry, plugin_registry: plugin_registry}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
