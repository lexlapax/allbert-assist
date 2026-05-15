defmodule AllbertAssist.App.Bootstrap do
  @moduledoc false

  use GenServer

  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

  require Logger

  @default_apps [AllbertAssist.App.CoreApp, AllbertAssist.App.StockSageStub]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts), do: {:ok, opts, {:continue, :register_apps}}

  @impl true
  def handle_continue(:register_apps, opts) do
    if Application.get_env(:allbert_assist, :apps_bootstrap, true) do
      register_configured_apps(opts)
    end

    {:noreply, Map.new(opts)}
  end

  defp register_configured_apps(opts) do
    registry = Keyword.get(opts, :registry, AllbertAssist.App.Registry)
    Enum.each(configured_apps!(), &register_app(&1, registry))
  end

  defp configured_apps! do
    apps = Application.get_env(:allbert_assist, :apps, default_apps())

    unless is_list(apps) do
      raise RuntimeError, "expected :allbert_assist, :apps to be a list, got: #{inspect(apps)}"
    end

    plugin_apps = PluginRegistry.registered_apps()

    apps
    |> drop_stubs_replaced_by_plugins(plugin_apps)
    |> Kernel.++(plugin_apps)
    |> Enum.uniq()
  end

  defp register_app(module, registry) do
    case AllbertAssist.App.Registry.register(module, server: registry) do
      {:ok, app_id} ->
        Logger.info("App registered: #{app_id}")

      {:error, reason} ->
        Logger.warning("App registration failed: #{inspect(module)}: #{inspect(reason)}")
    end
  end

  defp default_apps, do: @default_apps

  defp drop_stubs_replaced_by_plugins(apps, plugin_apps) do
    plugin_app_ids = MapSet.new(Enum.flat_map(plugin_apps, &safe_app_id/1))

    Enum.reject(apps, fn
      AllbertAssist.App.StockSageStub -> MapSet.member?(plugin_app_ids, :stocksage)
      _app -> false
    end)
  end

  defp safe_app_id(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :app_id, 0) do
      [module.app_id()]
    else
      []
    end
  rescue
    _exception -> []
  end
end
