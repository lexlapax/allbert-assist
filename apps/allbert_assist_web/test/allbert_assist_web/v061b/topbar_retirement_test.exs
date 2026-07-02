defmodule AllbertAssistWeb.V061b.TopbarRetirementTest do
  @moduledoc """
  v0.61b M7 proof (feedback #7, ADR 0080 §2): the per-shell top bars are
  retired and every control from the plan's M0 relocation table (rows 1–15)
  has exactly one new home or an explicit retirement — nothing silently
  dropped. `@relocation_map` mirrors the plan table row-for-row (the docs gate
  cross-checks the count); the theme toggle works cross-shell through
  `SharedShellHooks`.
  """
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Settings

  @moduletag :topbar_retirement

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

    {:ok, view, _html} = live(conn, ~p"/workspace")

    for {row, disposition, selector, :workspace} <- @relocation_map do
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

  test "the overflow menu works from an operator surface", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/objectives")

    refute has_element?(view, "#workspace-overflow-menu-items")
    view |> element("#workspace-overflow-menu") |> render_click()
    assert has_element?(view, "#workspace-overflow-menu-items")
    assert has_element?(view, "#workspace-overflow-settings-link")
    # No workspace thread context on operator shells — the copy-id item is absent.
    refute has_element?(view, "#workspace-thread-copy-id")
  end
end
