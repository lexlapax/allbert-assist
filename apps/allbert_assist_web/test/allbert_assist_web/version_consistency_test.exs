defmodule AllbertAssistWeb.VersionConsistencyTest do
  use ExUnit.Case, async: true

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
end
