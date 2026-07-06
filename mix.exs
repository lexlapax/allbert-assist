defmodule AllbertAssist.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.61.1",
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

  # v0.62 M0/M1 — the packaged `allbert` OTP release: both umbrella apps, ERTS
  # bundled (the spike/hand-wrapped mechanism; wrapper choice recorded in the
  # v0.62 plan M0 as-built). Web assets are built by the pre-assembly steps.
  defp releases do
    [
      allbert: [
        applications: [
          allbert_assist: :permanent,
          allbert_assist_web: :permanent
        ],
        include_executables_for: [:unix],
        include_erts: true,
        steps: [&build_web_assets/1, :assemble, &stage_plugins/1, &patch_macos_openssl/1]
      ]
    ]
  end

  # v0.62 M1: shipped plugins register from `RELEASE_ROOT/plugins` (the
  # M0-proven packaged layout; AllbertAssist.Plugin.Paths) — stage each
  # plugin's runtime folders (manifest + priv + skills, no source) into the
  # assembled release so registration is cwd-independent.
  defp stage_plugins(release) do
    target = Path.join(release.path, "plugins")
    File.mkdir_p!(target)

    "plugins"
    |> File.ls!()
    |> Enum.each(fn plugin_id ->
      source = Path.join("plugins", plugin_id)

      if File.dir?(source) do
        dest = Path.join(target, plugin_id)
        File.mkdir_p!(dest)

        for item <- ["allbert_plugin.json", "priv", "skills"],
            path = Path.join(source, item),
            File.exists?(path) do
          File.cp_r!(path, Path.join(dest, item))
        end
      end
    end)

    Mix.shell().info("==> staged shipped plugins into " <> target)
    release
  end

  # v0.62 M1 (M0 spike finding): a Homebrew/brew-built ERTS dynamically links
  # /opt/homebrew's libcrypto — the artifact would break on machines without
  # Homebrew OpenSSL. On darwin builds, bundle the linked OpenSSL dylibs next
  # to the crypto NIF and repoint via install_name_tool (+ ad-hoc re-sign,
  # mandatory on arm64 after mutation). No-op on other hosts.
  defp patch_macos_openssl(release) do
    case :os.type() do
      {:unix, :darwin} -> do_patch_macos_openssl(release)
      _other -> release
    end
  end

  defp do_patch_macos_openssl(release) do
    for nif <- Path.wildcard(Path.join(release.path, "lib/crypto-*/priv/lib/*.so")) do
      {links, 0} = System.cmd("otool", ["-L", nif])

      links
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.contains?(&1, "openssl"))
      |> Enum.map(&(&1 |> String.split(" ") |> hd()))
      |> Enum.each(fn dylib ->
        name = Path.basename(dylib)
        dest = Path.join(Path.dirname(nif), name)
        unless File.exists?(dest), do: File.cp!(dylib, dest)
        {_, 0} = System.cmd("install_name_tool", ["-change", dylib, "@loader_path/" <> name, nif])
        {_, 0} = System.cmd("codesign", ["-f", "-s", "-", dest])
        {_, 0} = System.cmd("codesign", ["-f", "-s", "-", nif])
        Mix.shell().info("==> bundled " <> name <> " for " <> Path.basename(nif))
      end)
    end

    release
  end

  defp build_web_assets(release) do
    Mix.shell().info("==> building web assets (npm ci + assets.deploy)")
    web_path = Path.join(["apps", "allbert_assist_web"])

    {_, 0} =
      System.cmd("mix", ["assets.npm"], cd: web_path, into: IO.stream(:stdio, :line))

    {_, 0} =
      System.cmd("mix", ["assets.deploy"],
        cd: web_path,
        env: [{"MIX_ENV", to_string(Mix.env())}],
        into: IO.stream(:stdio, :line)
      )

    release
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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
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
    Mix.Task.run("ecto.migrate.allbert", ["--quiet"])
    Application.put_env(:allbert_assist, :test_database_prepared?, true)
  end
end
