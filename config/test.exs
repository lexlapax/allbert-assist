import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :allbert_assist, AllbertAssist.Repo,
  database: Path.expand("../allbert_assist_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :allbert_assist_web, AllbertAssistWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "kJ5nb7nB0RUl64ivOrzlVn3dJKLBg0yhm7Cgw6j+FqFWWmcGcg7k9X5yp/pVDhDb",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# In test we don't send emails
config :allbert_assist, AllbertAssist.Mailer, adapter: Swoosh.Adapters.Test

config :allbert_assist, AllbertAssist.Jobs.Scheduler, enabled?: false

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
