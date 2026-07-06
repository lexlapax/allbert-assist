import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

config :allbert_assist_web, AllbertAssistWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# LLM provider credentials, read from the environment so secrets stay out
# of source control. Set whichever providers you actually use.
config :req_llm,
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  openai_api_key: System.get_env("OPENAI_API_KEY"),
  openrouter_api_key: System.get_env("OPENROUTER_API_KEY"),
  google_api_key: System.get_env("GOOGLE_API_KEY") || System.get_env("GEMINI_API_KEY")

if config_env() == :prod do
  env_value = fn name ->
    case System.get_env(name) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      nil ->
        nil
    end
  end

  # v0.62 M1: a packaged install must boot without hand-set env — Allbert Home
  # defaults to ~/.allbert (the same fallback AllbertAssist.Paths.home/0 uses;
  # inlined here because config providers should stay dependency-light).
  allbert_home =
    Path.expand(env_value.("ALLBERT_HOME") || env_value.("ALLBERT_HOME_DIR") || "~/.allbert")

  database_path =
    case env_value.("DATABASE_PATH") do
      nil -> Path.join([allbert_home, "db", "allbert.sqlite3"])
      path -> Path.expand(path)
    end

  File.mkdir_p!(Path.dirname(database_path))

  config :allbert_assist, AllbertAssist.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    busy_timeout: 15_000

  # The secret key base signs/encrypts cookies and similar secrets. v0.62 M1
  # (Locked Decision 13): when the env doesn't provide one, generate it on
  # first boot and persist it mode-600 under Allbert Home — a daemon has no
  # shell env to inherit and must never crash for want of a generated value.
  secret_key_base =
    case env_value.("SECRET_KEY_BASE") do
      value when is_binary(value) ->
        value

      nil ->
        skb_path = Path.join([allbert_home, "runtime", "secret_key_base"])

        case File.read(skb_path) do
          {:ok, value} when byte_size(value) >= 64 ->
            String.trim(value)

          _missing ->
            value = 64 |> :crypto.strong_rand_bytes() |> Base.encode64(padding: false)
            File.mkdir_p!(Path.dirname(skb_path))
            File.write!(skb_path, value)
            File.chmod!(skb_path, 0o600)
            value
        end
    end

  config :allbert_assist_web, AllbertAssistWeb.Endpoint,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## Using releases
  #
  # v0.62 M0/M1: the packaged binary starts the endpoint when PHX_SERVER is
  # set (the release env sets it; `mix phx.server` keeps its own path). The
  # boilerplate `server: true` comment this replaces meant a release booted
  # but never listened (Current Code State 5 in the v0.62 plan).
  if System.get_env("PHX_SERVER") do
    config :allbert_assist_web, AllbertAssistWeb.Endpoint, server: true
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :allbert_assist_web, AllbertAssistWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :allbert_assist_web, AllbertAssistWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :allbert_assist, AllbertAssist.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.

  config :allbert_assist, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
end
