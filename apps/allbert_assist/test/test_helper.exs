ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(AllbertAssist.Repo, :manual)

# v0.63 F2: provider credentials now resolve through the tier vault including the env tier
# (so an env-provided key is usable by the runtime and doctor — matching the readiness the
# wizard reports). That means a dev/CI shell with real provider keys exported would make the
# suite non-deterministic and, worse, hit the network from the model doctor. Clear the five
# provider env keys suite-wide so tests are hermetic; a test that wants an env-provided key
# sets it explicitly (and restores on_exit).
Enum.each(
  ~w(ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY GEMINI_API_KEY),
  &System.delete_env/1
)

# v0.63 M8.3: provider-credential writes/reads now route through Settings.Vault, whose
# default auto-resolution picks the OS Keychain on macOS. Pin the suite to the tier-2
# encrypted-file backend so tests never shell out to the real Keychain (equivalent to
# the pre-M8.3 behaviour where these flows called Settings.Secrets directly). Vault-tier
# tests override ALLBERT_VAULT_BACKEND per-test (with an injected `security` runner).
System.put_env("ALLBERT_VAULT_BACKEND", "encrypted_file")

# v0.63 F5: the intent router now hides capability-gated (voice off) and demo (StockSage)
# intents from the default shortlist. The eval corpus tests routing to those intents as if
# fully configured, so bypass the gate suite-wide (a focused DescriptorResolver test clears
# this flag to prove the production gate).
Application.put_env(:allbert_assist, :intent_descriptor_include_all, true)

test_home =
  Path.join(
    System.tmp_dir!(),
    "allbert-assist-test-home-#{System.unique_integer([:positive])}"
  )

Application.put_env(:allbert_assist, AllbertAssist.Paths, home: test_home)

Application.put_env(:allbert_assist, AllbertAssist.Skills.Registry,
  user_interoperable_root: Path.join(test_home, "agent-skills")
)

# v0.62 M8.24 (test isolation): stocksage is a shipped, boot-discovered plugin,
# but its App is not auto-registered in the global App.Registry at boot — so many
# tests register-if-absent + on_exit(unregister). Under async/lane concurrency
# that teardown intermittently pulled :stocksage out from under a concurrent test
# (Handoff.new!(app_id: :stocksage) -> {:invalid_app_id, :unknown_app}). Register
# it ONCE for the whole suite (idempotent, never torn down) so every register-if-
# absent guard goes inert and no teardown can race. See StockSageRegistryCase.
unless match?({:ok, _entry}, AllbertAssist.Plugin.Registry.lookup("stocksage")) do
  AllbertAssist.Plugin.Registry.register_module(StockSage.Plugin)
end

unless AllbertAssist.App.Registry.known_app_id?(:stocksage) do
  {:ok, :stocksage} = AllbertAssist.App.Registry.register(StockSage.App)
end
