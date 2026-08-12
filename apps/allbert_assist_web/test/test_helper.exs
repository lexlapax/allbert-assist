ExUnit.start()

# v1.4 M13: artifacts and stocksage moved their web surfaces into their own
# applications and now depend on Web instead of the other way around (see
# AllbertAssist.Pack.WebSurface) -- so Web's own `deps` no longer pull them in.
# Web DOES depend on the composition host directly, so unlike a pack's suite --
# which must start composition itself, after loading what it needs -- Mix
# starts composition automatically as part of Web's own OTP boot, before this
# file runs at all. That first composition attempt always fails closed with
# {:unknown_application, :allbert_artifacts}; ADR 0098 makes composition retry
# on the next app or plugin registration, so this has to be the FIRST
# registration this file causes, ahead of the stocksage block below, or that
# block's registration retries composition while artifacts is still missing.
AllbertAssist.TestSupport.PackBootstrap.ensure_loaded!([:allbert_artifacts, :stocksage])
AllbertAssist.TestSupport.PackBootstrap.ensure_registered!()

# A pack's migrations live in its own priv, and the residual runs migrations
# while IT starts -- before this file loads the packs. A packaged release loads
# every application before starting any, so `Application.app_dir/2` resolves
# there and the ordering never bites; an owner-scoped test VM loads them late, so
# the pack's tables would be absent. Re-run after the packs are loaded.
AllbertAssist.Database.migrate_repo(AllbertAssist.Repo, :up, all: true)

# v1.0.2 M2 drift-fix (v0.63 F5 oversight): F5 hides capability-gated and demo
# (StockSage) intents from the default shortlist and bypassed the gate in the
# CORE test_helper only — the web suite never got the same bypass, so every
# StockSage chat-routing LiveView test (e.g. the run_analysis approval-handoff
# flow) silently routed to list_analyses instead. Mirror the core suite-wide
# bypass; the production gate keeps its focused core-side proof.
Application.put_env(:allbert_assist, :intent_descriptor_include_all, true)

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

# v1.4 M1.a3: Web starts as an observer while composition is still collecting.
# Product LiveView tests begin only after the cold acknowledged epoch exists and
# the Web observer has adopted it; readiness-specific tests use private seams.
pack_ready_deadline = System.monotonic_time(:millisecond) + 60_000

pack_ready_wait = fn wait ->
  ready? =
    match?(
      {:ok, %{phase: :ready}},
      AllbertAssist.Pack.Readiness.status(timeout: 1_000)
    ) and match?({:ok, _epoch}, AllbertAssistWeb.PackReadiness.admit())

  if ready? do
    :ok
  else
    if System.monotonic_time(:millisecond) < pack_ready_deadline do
      Process.sleep(25)
      wait.(wait)
    else
      raise "Pack readiness did not open for Web owner tests"
    end
  end
end

pack_ready_wait.(pack_ready_wait)
Ecto.Adapters.SQL.Sandbox.mode(AllbertAssist.Repo, :manual)
