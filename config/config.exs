# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Configure Mix tasks and generators
config :allbert_assist,
  ecto_repos: [AllbertAssist.Repo]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :allbert_assist, AllbertAssist.Mailer, adapter: Swoosh.Adapters.Local

config :allbert_assist_web,
  ecto_repos: [AllbertAssist.Repo],
  generators: [context_app: :allbert_assist]

# Configures the endpoint
config :allbert_assist_web, AllbertAssistWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AllbertAssistWeb.ErrorHTML, json: AllbertAssistWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AllbertAssist.PubSub,
  live_view: [signing_salt: "nf/oWf2L"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  allbert_assist_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/allbert_assist_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  allbert_assist_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/allbert_assist_web", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Jido instance configuration. Tune as the agent footprint grows.
config :allbert_assist, AllbertAssist.Jido,
  max_tasks: 1_000,
  agent_pools: []

config :allbert_assist, AllbertAssist.JidoBacked.Supervisor,
  extra_children: [AllbertAssist.Objectives.Engine.Agent]

config :allbert_assist, AllbertAssist.JidoBacked,
  debug_agents: [
    {AllbertAssist.Objectives.Engine.Agent, AllbertAssist.Objectives.Engine.Agent}
  ]

# Jido.AI model aliases. Reference these by atom (`:fast`, `:capable`, ...)
# in agent code so swapping providers is a config-only change.
# Format is "<provider>:<model>". ReqLLM uses the OpenAI-compatible provider
# for local Ollama models, with the Ollama base URL configured in runtime.exs.
config :jido_ai,
  model_aliases: %{
    fast: "anthropic:claude-haiku-4-5",
    capable: "anthropic:claude-sonnet-4-5",
    slow: "anthropic:claude-sonnet-4-5",
    thinking: "anthropic:claude-opus-4-5",
    gpt: "openai:gpt-4o-mini",
    local: "openai:gemma4:26b"
  },
  llm_defaults: %{
    text: %{model: :fast, temperature: 0.2, max_tokens: 1024, timeout: 30_000},
    object: %{model: :thinking, temperature: 0.0, max_tokens: 1024, timeout: 30_000},
    stream: %{model: :fast, temperature: 0.2, max_tokens: 1024, timeout: 30_000}
  }

# Native objective and StockSage specialist coordinator actions can legally
# orchestrate multiple ordered stages of bounded LLM/provider calls. Keep
# Jido.Action's outer execution budget above the sum of the per-specialist
# `stocksage.native_agent_timeout_ms` defaults so the coordinator owns timeout
# semantics instead of being killed by the generic action runner first.
config :jido_action, default_timeout: 900_000

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
