defmodule AllbertComposition.MixProject do
  use Mix.Project

  def project do
    [
      app: :allbert_composition,
      version: "1.3.2",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  defp aliases do
    [
      test: [&prepare_test_database/1, "test"]
    ]
  end

  defp prepare_test_database(_args) do
    unless Application.get_env(:allbert_assist, :test_database_prepared?, false) do
      Mix.Task.run("allbert.ecto.migrate", ["--quiet"])
      Application.put_env(:allbert_assist, :test_database_prepared?, true)
    end
  end

  defp deps do
    [
      {:allbert_kernel, in_umbrella: true},
      {:allbert_assist, in_umbrella: true}
    ]
  end
end
