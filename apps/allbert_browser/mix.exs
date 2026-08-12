defmodule AllbertBrowser.MixProject do
  use Mix.Project

  def project do
    [
      app: :allbert_browser,
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

  # `allbert_research` is a genuine pack-to-pack edge, permitted by ADR 0098
  # section 2 and declared rather than inherited: AllbertBrowser.Actions.
  # ResearchHandoff calls AllbertResearch.DelegateObjective and .Runtime. While
  # both were path-injected into the residual that edge was invisible; extracting
  # research alone made it a warning, and under warnings-as-errors a gate failure.
  # The direction is acyclic -- research references nothing in this pack.
  defp deps do
    [
      {:allbert_kernel, in_umbrella: true},
      {:allbert_assist, in_umbrella: true},
      {:allbert_research, in_umbrella: true},
      {:jason, "~> 1.2"}
    ]
  end

  defp aliases do
    [test: [&prepare_test_database/1, "test"]]
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
      env: [allbert_pack: AllbertBrowser.Pack]
    ]
  end
end
