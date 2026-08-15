Code.require_file("scripts/release/final_artifact.exs", __DIR__)

defmodule AllbertAssist.Umbrella.MixProject do
  use Mix.Project

  alias AllbertAssist.Release.FinalArtifact

  def project do
    [
      apps_path: "apps",
      version: "1.4.0",
      start_permanent: Mix.env() == :prod,
      releases: releases(),
      deps: deps(),
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: dialyzer(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.post": :test
      ]
    ]
  end

  # v0.62 M0/M1 — the packaged `allbert` OTP release: ordered umbrella apps, ERTS
  # bundled (the spike/hand-wrapped mechanism; wrapper choice recorded in the
  # v0.62 plan M0 as-built). Web assets are built by the pre-assembly steps.
  defp releases do
    [
      allbert: [
        applications: [
          allbert_kernel: :permanent,
          allbert_assist: :permanent,
          allbert_notes_files: :permanent,
          allbert_telegram: :permanent,
          allbert_email: :permanent,
          allbert_research: :permanent,
          allbert_browser: :permanent,
          allbert_discord: :permanent,
          allbert_matrix: :permanent,
          allbert_signal: :permanent,
          allbert_slack: :permanent,
          allbert_tui: :permanent,
          allbert_whatsapp: :permanent,
          allbert_artifacts: :permanent,
          stocksage: :permanent,
          allbert_composition: :permanent,
          allbert_assist_web: :permanent
        ],
        include_executables_for: [:unix],
        include_erts: true,
        steps: [
          &build_web_assets/1,
          :assemble,
          &prune_browser_bridge_node_modules/1,
          &assert_external_browser_boundary/1,
          &patch_macos_openssl/1,
          &patch_linux_sctp/1,
          &install_dispatcher/1,
          &finalize_license_evidence/1
        ]
      ]
    ]
  end

  # v0.62 M8.6 (audit blocker fix): the OTP release generator emits `bin/allbert`
  # (start/stop/eval/rpc/version only). The operator dispatcher — the thing that
  # implements `serve`/`admin`/`ask`/first-run — is the `bin/allbert-dispatch`
  # overlay. Installer/formula/service/smoke all invoke `bin/allbert`, so without
  # this step the shipped `allbert admin …`/`allbert serve` fail with "Unknown
  # command". Per the operator decision, install the dispatcher AS `bin/allbert`:
  # rename the generated launcher to `bin/allbert-release` (safe — the launcher
  # hardcodes RELEASE_NAME=allbert and derives RELEASE_ROOT from $SELF's parent,
  # so the boot/name references do not depend on the filename), then move the
  # dispatcher overlay onto `bin/allbert`. The overlay's RELEASE_BIN points at
  # `allbert-release` so passthrough (start/eval/…) still reaches the generator.
  defp install_dispatcher(release) do
    bin = Path.join(release.path, "bin")
    generated = Path.join(bin, "allbert")
    renamed = Path.join(bin, "allbert-release")
    dispatcher = Path.join(bin, "allbert-dispatch")

    unless File.exists?(dispatcher) do
      Mix.raise(
        "install_dispatcher: overlay bin/allbert-dispatch missing from the assembled release"
      )
    end

    File.rename!(generated, renamed)
    File.rename!(dispatcher, generated)
    File.chmod!(generated, 0o755)

    Mix.shell().info(
      "==> installed operator dispatcher as bin/allbert (generated launcher -> bin/allbert-release)"
    )

    release
  end

  # v0.62 M1: shipped plugins register from `RELEASE_ROOT/plugins` (the
  # M0-proven packaged layout; AllbertAssist.Plugin.Paths) — stage each
  # plugin's runtime folders (manifest + priv + skills, no source) into the
  # assembled release so registration is cwd-independent.

  # v1.4 M13: the browser bridge's node_modules must not ship. That used to be a
  # plugin-id special case inside stage_plugins, excluding the tree while copying
  # apps/allbert_browser/priv. Once the browser became an OTP application the
  # copy stopped going through that path -- `:assemble` brings the whole priv/ of
  # every application -- so the exclusion moved here, after assembly, or 900-odd
  # vendored files would silently start shipping. The boundary smoke below
  # asserts the same property from the outside.
  defp prune_browser_bridge_node_modules(release) do
    release.path
    |> Path.join("lib/allbert_browser-*/priv/playwright_bridge/node_modules")
    |> Path.wildcard()
    |> Enum.each(&File.rm_rf!/1)

    release
  end

  # v1.4 M13 promoted this to a release step of its own. It used to run at the tail
  # of `stage_plugins/1`, and M13 retired that step: every plugin became an OTP
  # application, so there is nothing left to stage into `RELEASE_ROOT/plugins`.
  # Deleting the step wholesale would have taken this assertion with it -- Node,
  # Playwright and Chromium are host dependencies that must never be copied into
  # the artifact, and that is worth its own line in the pipeline rather than a
  # tail call inside something unrelated.
  defp assert_external_browser_boundary(release) do
    script = Path.join(["scripts", "smoke", "browser_runtime_boundary_smoke.sh"])

    case System.cmd("bash", [script, release.path], into: IO.stream(:stdio, :line)) do
      {_output, 0} -> release
      {_output, status} -> Mix.raise("external browser runtime boundary failed (#{status})")
    end
  end

  # v1.2.1 M0.a2: preserve a bundled macOS OpenSSL closure only when `otool`
  # measures an OpenSSL edge in the exact assembled crypto NIFs. The helper
  # copies only those measured libraries, rewrites them loader-relative, and
  # verifies both the resulting closure and ad-hoc signatures. Linux remains
  # external and does not enter this patch path.
  defp patch_macos_openssl(release) do
    FinalArtifact.patch_macos_openssl(release)
  end

  # v1.3 M9.b: OTP's socket NIF loads libsctp dynamically when the runtime was
  # built with SCTP. Own the exact small Debian library closure in Linux
  # artifacts so clean hosts do not emit loader warnings into CLI stdout.
  defp patch_linux_sctp(release) do
    FinalArtifact.patch_linux_sctp(release)
  end

  defp build_web_assets(release) do
    FinalArtifact.build_web_assets(release)
  end

  # The license finalizer is deliberately the final release step. It receives
  # Mix's resolved application closure, derives target/toolchain truth from the
  # running builder, then verifies the sealed tree against the digest returned
  # out-of-band by finalization. Nothing mutates the tree after this callback.
  defp finalize_license_evidence(release) do
    FinalArtifact.finalize_license_evidence(release)
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "allbert.test": :test]
    ]
  end

  defp dialyzer do
    build_path = System.get_env("MIX_BUILD_PATH") || "_build/#{Mix.env()}"

    [
      plt_add_apps: [:mix, :ex_unit],
      plt_core_path: build_path,
      plt_local_path: Path.join(build_path, "dialyxir.plt"),
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true,
      flags: [:error_handling, :missing_return, :extra_return, :underspecs]
    ]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options.
  #
  # Dependencies listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp deps do
    [
      # Required to run "mix format" on ~H/.heex files from the umbrella root
      {:phoenix_live_view, ">= 0.0.0"},
      # Tooling: static analysis, type checking, coverage, codemods
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      # v1.4 M13.3, operator decision 2026-08-12: `:prod` too. The gate measured
      # MIX_ENV=test while the artifact ships MIX_ENV=prod, so the build being
      # type-checked was not the build being shipped -- and the difference is not
      # cosmetic, because every `if Mix.env() == :test` seam changes which
      # branches exist. `runtime: false` keeps this out of the release: the
      # release names its applications explicitly and dialyxir is in no
      # application's closure. Verified by rebuilding and checking `lib/`.
      {:dialyxir, "~> 1.4", only: [:dev, :test, :prod], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},
      {:igniter, "~> 0.7", only: [:dev, :test]},
      {:owl, "~> 0.13"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  #
  # Aliases listed here are available only for this project
  # and cannot be accessed from applications inside the apps/ folder.
  defp aliases do
    [
      # run `mix setup` in all child apps
      setup: ["cmd mix setup"],
      "ecto.migrate": ["do --app allbert_assist cmd mix allbert.ecto.migrate"],
      "ecto.migrate.allbert": ["do --app allbert_assist cmd mix allbert.ecto.migrate"],
      "phx.server": ["do --app allbert_assist_web phx.server"],
      precommit: ["allbert.test commit"],
      check: ["format --check-formatted", "credo --strict", "dialyzer"],
      test: [&prepare_test_database/1, "test"]
    ]
  end

  defp prepare_test_database(_args) do
    # In-process, NOT the "ecto.migrate.allbert" alias: that alias shells out
    # (`cmd mix …`), and the subprocess BEAM's pid-qualified solo test DB
    # (config/test.exs) is a different file than this BEAM opens — root
    # `mix test` then boots against an unmigrated database.
    Mix.Task.run("allbert.ecto.migrate", ["--quiet"])
    Application.put_env(:allbert_assist, :test_database_prepared?, true)
  end
end
