defmodule StockSage.MixProject do
  use Mix.Project

  def project do
    [
      app: :stocksage,
      version: "1.3.2",
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # The v1.4 M13 web-surface seam (AllbertAssist.Pack.WebSurface) is the whole
  # reason this pack can depend on Web at all: before it, StockSageWeb.AnalysisLive
  # had to be named directly by the router, and Web naming a pack while the pack
  # depended on Web for `use AllbertAssistWeb, :live_view` was a cycle. Now Web
  # routes one generic host and resolves this module from the sealed projection,
  # so the edge runs one direction only.
  #
  # The remaining hex deps mirror what the residual already declares for the same
  # imports (ecto_sql/exqlite for the legacy-database import path, jido/jido_action/
  # jido_signal/jido_ai for the native specialist agents, decimal for outcome
  # returns, jason for bridge payload encoding) -- a pack that does not declare
  # what it directly calls works only while something else happens to pull it in.
  defp deps do
    [
      {:allbert_kernel, in_umbrella: true},
      {:allbert_assist, in_umbrella: true},
      {:allbert_assist_web, in_umbrella: true},
      {:ecto_sql, "~> 3.13"},
      {:exqlite, ">= 0.0.0"},
      {:decimal, "~> 3.0"},
      {:jason, "~> 1.2"},
      {:jido, "~> 2.3"},
      {:jido_action, "~> 2.3"},
      {:jido_signal, "~> 2.2"},
      {:jido_ai, "~> 2.2"}
    ]
  end

  # A pack lane runs from its own directory against a fresh test home, so its
  # SQLite file starts empty; the residual owns the schema and applies it through
  # this same task.
  defp aliases do
    [test: [&load_ambient_applications/1, &prepare_test_database/1, "test"]]
  end

  # v1.4 M13.2: load the applications above Web before `test` starts anything,
  # or composition's first attempt fails closed on an unloaded one. Resolved at
  # runtime because the helper compiles only under MIX_ENV=test; see
  # AllbertAssist.TestSupport.PackBootstrap.ensure_ambient_loaded!/0 for why.
  defp load_ambient_applications(_args) do
    Mix.Task.run("compile")
    apply(AllbertAssist.TestSupport.PackBootstrap, :ensure_ambient_loaded!, [])
  end

  defp prepare_test_database(_args) do
    unless Application.get_env(:allbert_assist, :test_database_prepared?, false) do
      Mix.Task.run("allbert.ecto.migrate", ["--quiet"])
      Application.put_env(:allbert_assist, :test_database_prepared?, true)
    end
  end

  def application do
    [
      extra_applications: [:logger],
      env: [allbert_pack: StockSage.Pack]
    ]
  end
end
