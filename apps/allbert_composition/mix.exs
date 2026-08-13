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
      test: ["compile", &load_ambient_applications/1, &prepare_test_database/1, "test"]
    ]
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
      mod: {AllbertComposition.Application, []},
      env: [allbert_gate_owner_manifests: [AllbertComposition.GateOwnerManifest]]
    ]
  end

  defp deps do
    [
      {:allbert_kernel, in_umbrella: true},
      {:allbert_assist, in_umbrella: true},
      # R0 frozen DAG: the composition host depends on every required native
      # pack. This edge is what starts the extracted pack, without any kernel
      # edit, which M9's acceptance forbids.
      {:allbert_notes_files, in_umbrella: true},
      {:allbert_telegram, in_umbrella: true},
      {:allbert_email, in_umbrella: true},
      {:allbert_research, in_umbrella: true},
      {:allbert_browser, in_umbrella: true},
      {:allbert_discord, in_umbrella: true},
      {:allbert_matrix, in_umbrella: true},
      {:allbert_signal, in_umbrella: true},
      {:allbert_slack, in_umbrella: true},
      {:allbert_tui, in_umbrella: true},
      {:allbert_whatsapp, in_umbrella: true}
      # allbert_artifacts and stocksage are deliberately ABSENT. Both contribute a
      # routed web surface, so both depend on allbert_assist_web -- and Web depends
      # on this host. Naming them here closes the loop
      # web -> composition -> pack -> web. They sit ABOVE Web in the DAG instead,
      # started by the release `applications:` list, and their metadata reaches the
      # projection through ProjectionProvider's application roster, which reads
      # `.app` files and needs no dependency edge.
    ]
  end
end
