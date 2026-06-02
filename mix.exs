defmodule AllbertAssist.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.44.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: dialyzer(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.post": :test
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "allbert.test": :test]
    ]
  end

  defp dialyzer do
    build_path = System.get_env("MIX_BUILD_PATH") || "_build/#{Mix.env()}"

    [
      plt_add_apps: [:mix, :ex_unit],
      plt_core_path: build_path,
      plt_local_path: Path.join(build_path, "dialyxir.plt"),
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true,
      flags: [:error_handling, :missing_return, :extra_return, :underspecs]
    ]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options.
  #
  # Dependencies listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp deps do
    [
      # Required to run "mix format" on ~H/.heex files from the umbrella root
      {:phoenix_live_view, ">= 0.0.0"},
      # Tooling: static analysis, type checking, coverage, codemods
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:igniter, "~> 0.7", only: [:dev, :test]}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  #
  # Aliases listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp aliases do
    [
      # run `mix setup` in all child apps
      setup: ["cmd mix setup"],
      "ecto.migrate": ["do --app allbert_assist cmd mix ecto.migrate.allbert"],
      "ecto.migrate.allbert": ["do --app allbert_assist cmd mix ecto.migrate.allbert"],
      "phx.server": ["do --app allbert_assist_web phx.server"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "credo --strict",
        "do --app allbert_assist cmd mix test",
        "do --app allbert_assist_web cmd mix test",
        "do --app allbert_assist cmd mix test ../../plugins/stocksage/test/stocksage ../../plugins/stocksage/test/mix",
        "do --app allbert_assist cmd mix test ../../plugins/allbert.telegram/test ../../plugins/allbert.email/test ../../plugins/allbert.notes_files/test"
      ],
      check: ["format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end
end
