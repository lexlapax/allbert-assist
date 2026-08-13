defmodule AllbertArtifacts.MixProject do
  use Mix.Project

  def project do
    [
      app: :allbert_artifacts,
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
  # reason this pack can depend on Web at all: before it, AllbertArtifactsWeb.ArtifactLive
  # had to be named directly by the router, and Web naming a pack while the pack
  # depended on Web for `use AllbertAssistWeb, :live_view` was a cycle. Now Web
  # routes one generic host and resolves this module from the sealed projection,
  # so the edge runs one direction only.
  defp deps do
    [
      {:allbert_kernel, in_umbrella: true},
      {:allbert_assist, in_umbrella: true},
      {:allbert_assist_web, in_umbrella: true}
    ]
  end

  # A pack lane runs from its own directory against a fresh test home, so its
  # SQLite file starts empty; the residual owns the schema and applies it through
  # this same task.
  defp aliases do
    [test: ["compile", &load_ambient_applications/1, &prepare_test_database/1, "test"]]
  end

  # v1.4 M13.2: put the applications above Web on the code path before `test`
  # starts anything, or composition's first attempt fails closed on one of them. The gate
  # runs `allbert.test.raw`, which bypasses this alias by design and does the
  # same thing itself; this covers a bare `mix test` from the app directory.
  # See AllbertAssist.TestSupport.PackBootstrap.ensure_ambient_reachable!/0.
  defp load_ambient_applications(_args),
    do: apply(AllbertAssist.TestSupport.PackBootstrap, :ensure_ambient_reachable!, [])

  defp prepare_test_database(_args) do
    unless Application.get_env(:allbert_assist, :test_database_prepared?, false) do
      Mix.Task.run("allbert.ecto.migrate", ["--quiet"])
      Application.put_env(:allbert_assist, :test_database_prepared?, true)
    end
  end

  def application do
    [
      extra_applications: [:logger],
      env: [allbert_pack: AllbertArtifacts.Pack]
    ]
  end
end
