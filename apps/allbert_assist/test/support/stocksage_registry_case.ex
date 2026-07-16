defmodule AllbertAssist.StockSageRegistryCase do
  @moduledoc """
  Test helper for StockSage plugin/app registry setup.

  StockSage.App action validation resolves through the registered action
  boundary, so tests that register or normalize the app must seed the plugin
  contribution first.

  v0.62 M8.24: `:stocksage` is now registered once for the whole suite in each
  app's `test_helper.exs`, so in practice `known_app_id?(:stocksage)` is already
  true and this `setup/1` is inert (it neither registers nor unregisters the app).
  The register-if-absent + unregister-only-if-we-registered guards below are kept
  defensively. Do NOT add an unconditional `App.Registry.unregister(:stocksage)`:
  the App.Registry is a single global GenServer shared across async tests, and an
  unconditional teardown would race — intermittently pulling `:stocksage` out from
  under a concurrent test (`Handoff.new!(app_id: :stocksage)` ->
  `{:invalid_app_id, :unknown_app}`).
  """

  import ExUnit.Assertions

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.TestSupport.ShippedRegistries

  def setup(_context \\ %{}) do
    plugin_registered? = match?({:ok, _entry}, PluginRegistry.lookup("stocksage"))
    app_registered? = AppRegistry.known_app_id?(:stocksage)

    unless plugin_registered? do
      assert {:ok, "stocksage"} = PluginRegistry.register_module(StockSage.Plugin)
    end

    unless app_registered? do
      assert {:ok, :stocksage} = AppRegistry.register(StockSage.App)
    end

    # v1.0.2 M2 drift-fix: the previous on_exit restored a SNAPSHOT taken at
    # this setup — if an earlier serial test had already left the registry
    # partial, the snapshot re-applied that damage and wiped every later
    # registration (watchdog-traced propagation). If stocksage was absent at
    # setup the registry was NOT in its baseline state, so converge to the
    # full shipped baseline instead of restoring the broken snapshot.
    ExUnit.Callbacks.on_exit(fn ->
      unless plugin_registered? and app_registered? do
        ShippedRegistries.restore!()
      end
    end)

    :ok
  end
end
