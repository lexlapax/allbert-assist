defmodule AllbertAssistWeb.V061b.TopbarRetirementTest do
  @moduledoc """
  v0.61b M7 proof (feedback #7, ADR 0080 §2): the per-shell top bars are
  retired and every control from the plan's M0 relocation table (rows 1–15)
  has exactly one new home or an explicit retirement — nothing silently
  dropped. `@relocation_map` mirrors the plan table row-for-row — the v061b
  sweep eval test cross-checks both counts (plan table + this mirror) so
  neither can drift alone; the theme toggle works cross-shell through
  `SharedShellHooks`.
  """
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Objectives
  alias AllbertAssist.Settings

  @moduletag :topbar_retirement

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  # Mirror of the plan's M0 relocation table (row, disposition, proof selector,
  # proof surface). Retired rows prove ABSENCE of the old control; relocated
  # rows prove PRESENCE at the new home.
  @relocation_map [
    {1, :retired, "#allbert-appbar", :workspace},
    {2, :retired, ".allbert-appbar-subtitle", :workspace},
    {3, :absorbed, "#sidebar-workspace-sections", :workspace},
    {4, :relocated, "#workspace-chat-region #workspace-context-indicator", :workspace},
    {5, :relocated, "#workspace-chat-region #objective-badges", :workspace_with_objective},
    {6, :relocated, "#workspace-chat-region #workspace-objective-count-chip", :workspace},
    {7, :retired_covered, "#workspace-canvas #workspace-canvas-cap-chip", :workspace},
    {8, :relocated, "#workspace-canvas #workspace-ephemeral-count-chip", :workspace},
    {9, :relocated, "#product-sidebar #workspace-theme-toggle", :workspace},
    {10, :relocated, "#product-sidebar #workspace-overflow-menu", :workspace},
    {11, :relocated, ".operator-view-header", :operator},
    {12, :relocated, "#sidebar-workspace-sections #workspace-launcher", :workspace},
    {13, :relocated, "#workspace-launcher-toggle[aria-controls='product-sidebar']", :workspace},
    {14, :relocated, "#workspace-chat-region .workspace-chat-header", :workspace},
    {15, :overflow, "#workspace-thread-copy-id", :workspace_overflow}
  ]

  test "the relocation map mirrors the plan table (15 rows) and holds on /workspace", %{
    conn: conn
  } do
    assert length(@relocation_map) == 15

    # v0.61b M9.1: row 5 needs an active objective for #objective-badges to
    # render — without this fixture the old `<- @relocation_map` filter
    # silently skipped the row (the one relocation nothing verified).
    assert {:ok, _objective} =
             Objectives.create_objective(%{
               user_id: "local",
               title: "Relocation row five",
               objective: "Objective badge fixture for the relocation sweep.",
               status: "running"
             })

    {:ok, view, _html} = live(conn, ~p"/workspace")

    workspace_rows =
      Enum.filter(@relocation_map, fn {_row, _disposition, _selector, surface} ->
        surface in [:workspace, :workspace_with_objective]
      end)

    # Rows 11 (operator) and 15 (overflow) are proven by their own tests below;
    # everything else must resolve here — no surface tag may silently drop out.
    assert length(workspace_rows) == 13

    for {row, disposition, selector, _surface} <- workspace_rows do
      case disposition do
        :retired ->
          refute has_element?(view, selector), "row #{row}: #{selector} must be retired"

        _present ->
          assert has_element?(view, selector), "row #{row}: #{selector} missing at its new home"
      end
    end

    # Row 15: copy-conversation-id survives inside the overflow menu (workspace only).
    view |> element("#workspace-overflow-menu") |> render_click()
    assert has_element?(view, "#workspace-thread-copy-id")

    IO.puts(
      "topbar-retired-relocation-001 status=pass rows=15 appbar=retired " <>
        "homes=chat_header+pane_header+sidebar_footer nothing_dropped=true"
    )
  end

  test "no persistent top bar on any shell; per-view headers carry context", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    refute has_element?(view, "#allbert-appbar")
    refute has_element?(view, ".operator-shell-topbar")

    for {path, title} <- [{~p"/jobs", "Scheduled Jobs"}, {~p"/objectives", "Objectives"}] do
      {:ok, view, _html} = live(conn, path)
      refute has_element?(view, ".operator-shell-topbar")
      refute has_element?(view, "#allbert-appbar")
      assert render(element(view, ".operator-view-header")) =~ title
    end
  end

  test "the theme toggle cycles cross-shell from an operator surface", %{conn: conn} do
    # The theme mode persists in Settings across tests — pin the start state.
    assert {:ok, _setting} = Settings.put("workspace.theme.mode", "system", %{audit?: false})
    on_exit(fn -> Settings.put("workspace.theme.mode", "system", %{audit?: false}) end)

    {:ok, view, _html} = live(conn, ~p"/jobs")

    assert has_element?(view, "#workspace-theme-toggle[data-current-theme='system']")

    view |> element("#workspace-theme-toggle") |> render_click()
    assert has_element?(view, "#workspace-theme-toggle[data-current-theme='dark']")

    view |> element("#workspace-theme-toggle") |> render_click()
    assert has_element?(view, "#workspace-theme-toggle[data-current-theme='light']")
  end

  test "the shared-shell theme read falls back to system on a broken snapshot" do
    # v0.61b M9.2: a failing/garbled resolved_settings_snapshot action must pin
    # every shell to a safe theme, never crash the mount.
    alias AllbertAssistWeb.Live.SharedShellHooks

    good = %{"workspace" => %{"theme" => %{"mode" => "dark"}}}
    junk = %{"workspace" => %{"theme" => %{"mode" => "neon"}}}

    assert SharedShellHooks.theme_from_snapshot({:ok, %{status: :completed, settings: good}}) ==
             "dark"

    assert SharedShellHooks.theme_from_snapshot({:ok, %{status: :completed, settings: junk}}) ==
             "system"

    assert SharedShellHooks.theme_from_snapshot({:ok, %{status: :failed}}) == "system"
    assert SharedShellHooks.theme_from_snapshot({:error, :action_denied}) == "system"
  end

  test "the overflow menu works from an operator surface", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/objectives")

    refute has_element?(view, "#workspace-overflow-menu-items")
    view |> element("#workspace-overflow-menu") |> render_click()
    assert has_element?(view, "#workspace-overflow-menu-items")
    assert has_element?(view, "#workspace-overflow-settings-link")
    # No workspace thread context on operator shells — the copy-id item is absent.
    refute has_element?(view, "#workspace-thread-copy-id")

    # v0.61b M9.1 (ADR 0080 focus-return guardrail): Escape closes AND returns
    # focus to the overflow trigger via the bound JS chain.
    wrap = render(element(view, ".allbert-overflow-wrap"))
    assert wrap =~ "close_workspace_overflow_menu"
    assert wrap =~ "focus"
    assert wrap =~ "#workspace-overflow-menu"
  end

  test "the sidebar-footer overflow menu geometry and focus indicator are guarded" do
    # v0.61b M9.1 gate hardening: both were found broken manually — the menu
    # kept its appbar-era top/right dropdown geometry (opened off-screen from
    # the footer) and its items lost their focus ring outside #workspace-shell.
    css = File.read!(@css_path)

    [menu] =
      Regex.run(~r/\n\.workspace-overflow-menu\s*\{(.*?)\n\}/s, css, capture: :all_but_first)

    assert menu =~ "bottom: calc(100% + 0.25rem)"
    assert menu =~ "left: 0"
    refute menu =~ ~r/\n  top:/

    assert Regex.match?(
             ~r/\.workspace-tile-menu-item:focus-visible\s*\{\s*outline:\s*2px solid var\(--workspace-focus\)/,
             css
           )
  end
end
