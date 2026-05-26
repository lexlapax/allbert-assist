defmodule AllbertAssistWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :allbert_assist_web,
      version: "0.37.5",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {AllbertAssistWeb.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib" | shipped_plugin_web_paths()] ++ ["test/support"]
  defp elixirc_paths(_), do: ["lib" | shipped_plugin_web_paths()]

  defp shipped_plugin_web_paths do
    [
      Path.expand("../../plugins/stocksage/lib/stocksage_web", __DIR__)
    ]
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.5"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:swoosh, "~> 1.16"},
      {:allbert_assist, in_umbrella: true},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.npm", "assets.setup", "assets.build"],
      "assets.npm": [&npm_install/1],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind allbert_assist_web", "esbuild allbert_assist_web"],
      "assets.deploy": [
        "tailwind allbert_assist_web --minify",
        "esbuild allbert_assist_web --minify",
        "phx.digest"
      ]
    ]
  end

  defp npm_install(_args) do
    {_, status} =
      System.cmd("npm", ["ci", "--no-audit", "--no-fund"],
        cd: Path.expand("assets", __DIR__),
        into: IO.stream()
      )

    if status != 0 do
      Mix.raise("npm ci failed for allbert_assist_web assets")
    end
  end
end
