defmodule AllbertAssistWeb.VersionConsistencyTest do
  use ExUnit.Case, async: true
  @moduletag :external_runtime_serial

  alias AllbertAssist.App.CoreApp

  @moduledoc """
  M8.7 drift guard. The app version lives in two app `:vsn` sources — `:allbert_assist`
  drives the `allbert --version` CLI banner and (via `CoreApp.version/0`) the MCP/ACP
  `serverInfo.version`; `:allbert_assist_web` drives the served asset `v=` cache-bust.
  They must move in lockstep, and `CoreApp.version/0` must track `:vsn` rather than a
  hand-maintained literal, so a partial `0.62.1 → 0.63.0` bump can't ship a mismatched
  protocol/asset version.
  """

  test "CoreApp.version/0 derives from the :allbert_assist :vsn (no hand-maintained literal)" do
    assert CoreApp.version() ==
             to_string(Application.spec(:allbert_assist, :vsn))
  end

  test "the CLI-banner app and the asset-version app agree on version" do
    core = to_string(Application.spec(:allbert_assist, :vsn))
    web = to_string(Application.spec(:allbert_assist_web, :vsn))

    assert core == web,
           "version drift: allbert_assist=#{core} allbert_assist_web=#{web} — " <>
             "bump both mix.exs :vsn (and the umbrella) in lockstep at release"
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
  # correct (it did: the .gz still carried v0.62.1 at 1.0.0).
  test "the tracked gzip service-worker variant matches the source" do
    assert :zlib.gunzip(File.read!(@service_worker_path <> ".gz")) ==
             File.read!(@service_worker_path),
           "workspace-sw.js.gz is stale — regenerate it (gzip -kf9 workspace-sw.js) " <>
             "in the same commit whenever workspace-sw.js changes"
  end
end
