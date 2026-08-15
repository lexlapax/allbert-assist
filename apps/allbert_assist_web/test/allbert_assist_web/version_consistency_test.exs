unless Code.ensure_loaded?(AllbertAssist.Umbrella.MixProject) and
         function_exported?(AllbertAssist.Umbrella.MixProject, :project, 0) do
  Code.require_file(Path.expand("../../../../mix.exs", __DIR__))
end

defmodule AllbertAssistWeb.VersionConsistencyTest do
  use ExUnit.Case, async: true
  @moduletag :external_runtime_serial

  alias AllbertAssist.App.CoreApp
  alias AllbertAssist.Umbrella.MixProject

  @moduledoc """
  M8.7 drift guard, extended for the v1.4 application boundary. The umbrella and
  every declared Allbert OTP application move in lockstep. `:allbert_assist` drives the
  `allbert --version` CLI banner and (via `CoreApp.version/0`) the MCP/ACP
  `serverInfo.version`; `:allbert_assist_web` drives the served asset `v=` cache-bust.
  `CoreApp.version/0` must track `:vsn` rather than a hand-maintained literal, so a
  partial bump cannot ship a mismatched protocol, topology, or asset version.
  """

  @release_version "1.4.0"
  @expected_umbrella_applications ~w(
    allbert_artifacts
    allbert_assist
    allbert_assist_web
    allbert_browser
    allbert_composition
    allbert_discord
    allbert_email
    allbert_kernel
    allbert_matrix
    allbert_notes_files
    allbert_research
    allbert_signal
    allbert_slack
    allbert_telegram
    allbert_tui
    allbert_whatsapp
    stocksage
  )a

  test "CoreApp.version/0 derives from the :allbert_assist :vsn (no hand-maintained literal)" do
    assert CoreApp.version() ==
             to_string(Application.spec(:allbert_assist, :vsn))
  end

  test "the umbrella and every declared OTP application carry the v1.4 release version" do
    applications = declared_umbrella_applications()

    assert applications == @expected_umbrella_applications,
           "umbrella application roster drift: #{inspect(applications)} — " <>
             "extend the version checkpoint when an application joins or leaves the release"

    versions =
      applications
      |> Enum.map(fn application ->
        assert :ok = load_application(application)
        {application, Application.spec(application, :vsn) |> to_string()}
      end)
      |> Map.new()
      |> Map.put(:umbrella, MixProject.project() |> Keyword.fetch!(:version))

    assert Map.values(versions) |> Enum.uniq() == [@release_version],
           "version drift across the umbrella release: #{inspect(versions)} — " <>
             "bump root mix.exs and every apps/*/mix.exs version in lockstep at release"
  end

  test "the Web application depends on composition and retains its residual dependency" do
    applications = Application.spec(:allbert_assist_web, :applications)

    assert :allbert_composition in applications
    assert :allbert_assist in applications
  end

  # v1.0.1 M3: the service worker is cache-first for /assets/* and only purges
  # superseded caches when CACHE_NAME changes, so a missed bump quietly strands
  # old caches (shipped stranded at v0.62.1 through the 1.0.0 release). This
  # rides the v1_version_consistency step of every release gate; the compile-time
  # version keeps it free of runtime app state.
  @web_vsn Mix.Project.config()[:version]
  @service_worker_path Path.expand("../../priv/static/workspace-sw.js", __DIR__)

  test "the service-worker cache name moves in lockstep with the app version" do
    service_worker = File.read!(@service_worker_path)

    assert service_worker =~
             ~s(const CACHE_NAME = "allbert-workspace-shell-v#{@web_vsn}";),
           "workspace-sw.js CACHE_NAME does not match version #{@web_vsn} — " <>
             "bump priv/static/workspace-sw.js in the same commit as the mix.exs bumps"
  end

  # Plug.Static serves the tracked .gz variant to gzip-accepting clients, so a
  # stale workspace-sw.js.gz ships the OLD service worker even when the .js is
  # correct (it did: the .gz still carried v0.62.1 at 1.0.0). Gzip headers can
  # vary across tools and hosts, so semantic equality is the source contract;
  # release assembly separately preserves the repository's exact gzip bytes.
  test "the tracked gzip service-worker variant matches the source" do
    assert :zlib.gunzip(File.read!(@service_worker_path <> ".gz")) ==
             File.read!(@service_worker_path),
           "workspace-sw.js.gz is stale — regenerate it through " <>
             "the Phoenix asset digest in the same commit whenever workspace-sw.js changes"
  end

  defp declared_umbrella_applications do
    [Path.expand("../../../..", __DIR__), "apps", "*", "mix.exs"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(fn mixfile ->
      mixfile
      |> Path.dirname()
      |> Path.basename()
      |> String.to_existing_atom()
    end)
    |> Enum.sort()
  end

  defp load_application(application) do
    case Application.load(application) do
      :ok -> :ok
      {:error, {:already_loaded, ^application}} -> :ok
    end
  end
end
