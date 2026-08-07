defmodule AllbertKernel.MixProject do
  use Mix.Project

  def project do
    [
      app: :allbert_kernel,
      version: "1.3.2",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  def application do
    [
      extra_applications: [:crypto],
      env: [allbert_pack: AllbertAssist.Pack.Kernel]
    ]
  end
end
