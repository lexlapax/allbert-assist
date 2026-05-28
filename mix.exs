defmodule AllbertAssist.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.39.0",
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
      preferred_envs: [precommit: :test]
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
      "phx.server": [&maybe_bootstrap_dev_database/1, "do --app allbert_assist_web phx.server"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "credo --strict",
        "do --app allbert_assist cmd mix test",
        "do --app allbert_assist_web cmd mix test",
        "do --app allbert_assist cmd mix test ../../plugins/stocksage/test/stocksage ../../plugins/stocksage/test/mix",
        "do --app allbert_assist cmd mix test ../../plugins/allbert.telegram/test ../../plugins/allbert.email/test"
      ],
      check: ["format --check-formatted", "credo --strict", "dialyzer"]
    ]
  end

  defp maybe_bootstrap_dev_database(_args) do
    cond do
      Mix.env() != :dev ->
        :ok

      dev_auto_migrate_disabled?() ->
        :ok

      explicit_database_path?() ->
        :ok

      is_nil(allbert_home_env()) ->
        :ok

      dev_auto_migrate_enabled?() ->
        run_dev_database_bootstrap(:migrate)

      missing_or_empty_dev_database?() ->
        run_dev_database_bootstrap(:bootstrap)

      true ->
        :ok
    end
  end

  defp run_dev_database_bootstrap(mode) do
    database_path = dev_database_path!()

    File.mkdir_p!(Path.dirname(database_path))

    message =
      if mode == :bootstrap do
        "Bootstrapping Allbert dev database at #{database_path}"
      else
        "Migrating Allbert dev database at #{database_path}"
      end

    Mix.shell().info(message)
    Mix.Task.reenable("do")

    Mix.Task.run("do", [
      "--app",
      "allbert_assist",
      "ecto.migrate.allbert",
      "--quiet",
      "--pool-size",
      "1"
    ])
  end

  defp missing_or_empty_dev_database? do
    database_path = dev_database_path!()

    not File.exists?(database_path) or File.stat!(database_path).size == 0
  end

  defp dev_database_path! do
    case Application.get_env(:allbert_assist, AllbertAssist.Repo, [])[:database] do
      database_path when is_binary(database_path) -> Path.expand(database_path)
      _ -> Mix.raise("Allbert dev database path is not configured")
    end
  end

  defp allbert_home_env do
    System.get_env("ALLBERT_HOME") || System.get_env("ALLBERT_HOME_DIR")
  end

  defp explicit_database_path? do
    present_env?("DATABASE_PATH")
  end

  defp dev_auto_migrate_enabled? do
    truthy_env?("ALLBERT_DEV_AUTO_MIGRATE")
  end

  defp dev_auto_migrate_disabled? do
    falsy_env?("ALLBERT_DEV_AUTO_MIGRATE")
  end

  defp truthy_env?(name) do
    System.get_env(name)
    |> normalize_env_value()
    |> Kernel.in(["1", "true", "yes", "on"])
  end

  defp falsy_env?(name) do
    System.get_env(name)
    |> normalize_env_value()
    |> Kernel.in(["0", "false", "no", "off"])
  end

  defp present_env?(name) do
    case System.get_env(name) do
      nil -> false
      value -> String.trim(value) != ""
    end
  end

  defp normalize_env_value(nil), do: nil

  defp normalize_env_value(value) do
    value
    |> String.trim()
    |> String.downcase()
  end
end
