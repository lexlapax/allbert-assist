defmodule AllbertAssist.StockSageRegistryCase do
  @moduledoc """
  Test helper for StockSage plugin/app registry setup.

  StockSage.App action validation resolves through the registered action
  boundary, so tests that register or normalize the app must seed the plugin
  contribution first.
  """

  import ExUnit.Assertions

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

  def setup(_context \\ %{}) do
    registered_plugins = PluginRegistry.registered_plugins()
    registered_diagnostics = PluginRegistry.diagnostics()
    plugin_registered? = match?({:ok, _entry}, PluginRegistry.lookup("stocksage"))
    app_registered? = AppRegistry.known_app_id?(:stocksage)

    unless plugin_registered? do
      assert {:ok, "stocksage"} = PluginRegistry.register_module(StockSage.Plugin)
    end

    unless app_registered? do
      assert {:ok, :stocksage} = AppRegistry.register(StockSage.App)
    end

    ExUnit.Callbacks.on_exit(fn ->
      unless app_registered?, do: AppRegistry.unregister(:stocksage)

      unless plugin_registered? do
        restore_plugin_registry(registered_plugins, registered_diagnostics)
      end
    end)

    :ok
  end

  defp restore_plugin_registry(plugins, diagnostics) do
    PluginRegistry.clear()
    Enum.each(plugins, &PluginRegistry.register_entry/1)
    Enum.each(diagnostics, &restore_plugin_diagnostics/1)
  end

  defp restore_plugin_diagnostics({plugin_id, diagnostics}) do
    PluginRegistry.put_diagnostics(plugin_id, diagnostics)
  end
end
