defmodule StockSageWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :stocksage_web,
      version: "0.20.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:allbert_assist_web, in_umbrella: true},
      {:stocksage, in_umbrella: true}
    ]
  end
end
