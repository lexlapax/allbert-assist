defmodule AllbertSlack.MixProject do
  use Mix.Project

  def project do
    [
      app: :allbert_slack,
      version: "1.4.0",
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

  defp deps do
    [
      {:allbert_kernel, in_umbrella: true},
      {:allbert_assist, in_umbrella: true}
    ]
  end

  # A pack lane runs from its own directory against a fresh test home, so its
  # database starts empty; the residual owns the schema and applies it here.
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
      mod: {AllbertSlack.Application, []},
      env: [allbert_pack: AllbertSlack.Pack]
    ]
  end
end
