defmodule AllbertAssist.MixProject do
  use Mix.Project

  def project do
    [
      app: :allbert_assist,
      version: "0.51.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {AllbertAssist.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test) do
    ["lib" | shipped_plugin_paths()] ++ ["test/support" | shipped_plugin_test_support_paths()]
  end

  defp elixirc_paths(_), do: ["lib" | shipped_plugin_paths()]

  defp shipped_plugin_paths do
    [
      Path.expand("../../plugins/allbert.telegram/lib", __DIR__),
      Path.expand("../../plugins/allbert.email/lib", __DIR__),
      Path.expand("../../plugins/allbert.discord/lib", __DIR__),
      Path.expand("../../plugins/allbert.notes_files/lib", __DIR__),
      Path.expand("../../plugins/allbert.browser/lib", __DIR__),
      Path.expand("../../plugins/allbert.artifacts/lib/allbert_artifacts", __DIR__),
      Path.expand("../../plugins/allbert.artifacts/lib/mix", __DIR__),
      Path.expand("../../plugins/allbert.research/lib", __DIR__),
      Path.expand("../../plugins/stocksage/lib/stocksage", __DIR__),
      Path.expand("../../plugins/stocksage/lib/mix", __DIR__)
    ]
  end

  defp shipped_plugin_test_support_paths do
    [
      Path.expand("../../plugins/stocksage/test/support", __DIR__)
    ]
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:dns_cluster, "~> 0.2.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:jason, "~> 1.2"},
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.0"},
      {:req, "~> 0.5"},
      {:websockex, "~> 0.5"},
      {:hermes_mcp, "~> 0.14"},
      {:plug, "~> 1.19"},
      {:bandit, "~> 1.5"},
      {:tzdata, "~> 1.1"},
      {:jsv, "~> 0.19"},
      {:yaml_elixir, "~> 2.12"},
      {:ymlr, "~> 5.0"},
      # Jido agent framework + ecosystem
      # Local override until upstream Memento releases an Elixir 1.19-safe
      # replacement for its conflicting `record/0` typespec.
      {:memento, path: "../../vendor/memento", override: true},
      {:jido, "~> 2.3"},
      {:jido_action, "~> 2.3"},
      {:jido_signal, "~> 2.2"},
      {:jido_ai, "~> 2.2"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate.allbert", "run #{__DIR__}/priv/repo/seeds.exs"],
      "ecto.migrate.allbert": ["allbert.ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: [&prepare_test_database/1, "test"]
    ]
  end

  defp prepare_test_database(_args) do
    unless Application.get_env(:allbert_assist, :test_database_prepared?, false) do
      Mix.Task.run("allbert.ecto.migrate", ["--quiet"])
      Application.put_env(:allbert_assist, :test_database_prepared?, true)
    end
  end
end
