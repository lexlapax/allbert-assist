import Config

env_value = fn name ->
  case System.get_env(name) do
    value when is_binary(value) ->
      value = String.trim(value)
      if value == "", do: nil, else: value

    nil ->
      nil
  end
end

partition = env_value.("MIX_TEST_PARTITION")
home_from_env = env_value.("ALLBERT_HOME") || env_value.("ALLBERT_HOME_DIR")

generated_partition_home =
  if partition do
    Path.join([System.tmp_dir!(), "allbert_test_partitions", "p#{partition}", "home"])
  end

test_home = home_from_env || generated_partition_home

if generated_partition_home && is_nil(home_from_env) do
  System.put_env("ALLBERT_HOME", generated_partition_home)
  System.put_env("ALLBERT_HOME_DIR", generated_partition_home)
end

database_path =
  cond do
    path = env_value.("DATABASE_PATH") ->
      Path.expand(path)

    home = test_home ->
      Path.expand(Path.join([home, "db", "allbert.sqlite3"]))

    true ->
      Path.expand("../allbert_assist_test.db", __DIR__)
  end

if partition && is_nil(env_value.("DATABASE_PATH")) do
  System.put_env("DATABASE_PATH", database_path)
end

File.mkdir_p!(Path.dirname(database_path))

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
# pool_size must comfortably exceed `mix test`'s concurrency (max_cases defaults
# to schedulers_online * 2). With pool_size: 5 against ~40 concurrent cases, a
# single held connection (e.g. a LiveView Task running inside a Repo transaction)
# starved the pool and surfaced as DBConnection queue_timeout flakes in the
# release gate's web/LiveView tests. Track the scheduler count plus headroom for
# connections held across async boundaries.
config :allbert_assist, AllbertAssist.Repo,
  database: database_path,
  pool_size: System.schedulers_online() * 2 + 8,
  journal_mode: :wal,
  busy_timeout: 15_000,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :allbert_assist_web, AllbertAssistWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "kJ5nb7nB0RUl64ivOrzlVn3dJKLBg0yhm7Cgw6j+FqFWWmcGcg7k9X5yp/pVDhDb",
  server: false

config :allbert_assist_web, preview_routes: true

# Print only warnings and errors during test
config :logger, level: :warning

# In test we don't send emails
config :allbert_assist, AllbertAssist.Mailer, adapter: Swoosh.Adapters.Test

config :allbert_assist, AllbertAssist.Jobs.Scheduler, enabled?: false

config :allbert_assist, AllbertAssist.Workspace.Fragment.SigningSecret, bootstrap_on_start?: false

config :allbert_assist, StockSage.Agents.LLM, enabled?: false

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# v0.54 intent router: force the deterministic strategy in tests so the suite
# never reaches the live Ollama embedding / LLM disambiguation path. Router-
# specific tests opt in by setting :intent_router_strategy_override to
# :two_stage_local in their setup (with FakeEmbedder/FakeDisambiguator).
config :allbert_assist, intent_router_strategy_override: :deterministic

# Keep the router Index from subscribing to the SignalBus in tests — a stray
# dynamic-codegen signal must not trigger a live-embedder rebuild. The reindex
# handle_info logic is unit-tested directly (router_index_reindex_test).
config :allbert_assist, :intent_index_reindex_on_signal, false
