defmodule AllbertTelegram.MixProject do
  use Mix.Project

  def project do
    [
      app: :allbert_telegram,
      version: "1.3.2",
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # The R0 frozen DAG (v1.4 plan) gives this pack exactly two direct Allbert
  # dependencies, the same pair notes_files takes. The kernel supplies Action,
  # Paths, Security and EffectGuard; the residual supplies Channels, Identity,
  # Runtime, Settings, External and Surface.Renderer. That is a pack-to-pack
  # edge, permitted by ADR 0098 section 2, and acyclic: after M12 nothing
  # outside this application references the AllbertTelegram namespace.
  defp deps do
    [
      {:allbert_kernel, in_umbrella: true},
      {:allbert_assist, in_umbrella: true}
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      env: [allbert_pack: AllbertTelegram.Pack]
    ]
  end
end
