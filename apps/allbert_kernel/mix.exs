defmodule AllbertKernel.MixProject do
  use Mix.Project

  def project do
    [
      app: :allbert_kernel,
      version: "1.4.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # The four libraries the relocated concerns reach, each admitted by the M7.1
  # closure ledger from a real call or struct match rather than discovered
  # after the move: Exqlite for the single-writer lock, Jason for external
  # request encoding, and the Jido action and signal contracts for the
  # Capability Plane.
  defp deps do
    [
      {:exqlite, ">= 0.0.0"},
      {:jason, "~> 1.2"},
      {:jido_action, "~> 2.3"},
      {:jido_signal, "~> 2.2"}
    ]
  end

  def application do
    [
      mod: {AllbertKernel.Application, []},
      extra_applications: [:crypto],
      env: [allbert_pack: AllbertAssist.Pack.Kernel]
    ]
  end
end
