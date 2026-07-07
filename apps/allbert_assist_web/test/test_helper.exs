ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(AllbertAssist.Repo, :manual)

# v0.62 M8.24 (test isolation): register the shipped stocksage plugin's App once
# for the whole web suite (idempotent, never torn down) so LiveView tests that use
# `app_id: :stocksage` (e.g. intent-handoff) don't depend on ambient global
# App.Registry state that a concurrent core test's on_exit(unregister) could tear
# down mid-run. Mirrors the core test_helper; see StockSageRegistryCase.
unless match?({:ok, _entry}, AllbertAssist.Plugin.Registry.lookup("stocksage")) do
  AllbertAssist.Plugin.Registry.register_module(StockSage.Plugin)
end

unless AllbertAssist.App.Registry.known_app_id?(:stocksage) do
  {:ok, :stocksage} = AllbertAssist.App.Registry.register(StockSage.App)
end
