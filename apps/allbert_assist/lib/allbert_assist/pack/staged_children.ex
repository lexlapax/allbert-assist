defmodule AllbertAssist.Pack.StagedChildren do
  @moduledoc false

  use GenServer

  alias AllbertAssist.Pack.{ActivationContext, ActivationGuard}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    context = Keyword.fetch!(opts, :allbert_pack_activation)
    carrier = [allbert_pack_activation: context]
    app_registry = Keyword.get(opts, :app_registry, AllbertAssist.App.Registry)

    app_dynamic_supervisor =
      Keyword.get(opts, :app_dynamic_supervisor, AllbertAssist.App.DynamicSupervisor)

    plugin_registry = Keyword.get(opts, :plugin_registry, AllbertAssist.Plugin.Registry)

    plugin_child_supervisor =
      Keyword.get(opts, :plugin_child_supervisor, AllbertAssist.Plugin.ChildSupervisor)

    with %ActivationContext{} <- context,
         :ok <- ActivationGuard.validate(carrier),
         :ok <-
           AllbertAssist.App.Registry.activate_staged_children(carrier, server: app_registry),
         :ok <-
           AllbertAssist.Plugin.Bootstrap.activate_staged_children(carrier,
             registry: plugin_registry,
             child_supervisor: plugin_child_supervisor
           ) do
      {:ok, %{app_dynamic_supervisor: app_dynamic_supervisor}}
    else
      {:error, reason} -> {:stop, reason}
      _other -> {:stop, :product_not_ready}
    end
  end
end
