defmodule AllbertAssistWeb.V061b.SidebarCollapseTest do
  @moduledoc """
  v0.61b M8 proof (feedback #3, ADR 0080 §4): the consolidated sidebar
  collapses expanded → icon rail → fully hidden with correct a11y
  (`aria-expanded` on the stable-named toggle, hidden nav unfocusable via
  `display:none`, a slim autofocused reopen affordance) and client-side
  persistence (`LayoutPrefs` restores `allbert.sidebar.state.v1` via
  `set_sidebar_state`). Expanded is the default. The workspace sections open
  from the rail as a click-activated flyout (operator decision 2026-07-02).
  """
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :sidebar_collapse

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @js_path Path.expand("../../../assets/js/app.js", __DIR__)

  test "expanded → rail → expanded cycle with correct toggle a11y", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    # Default is expanded.
    assert has_element?(view, "#product-sidebar[data-sidebar-state='expanded']")
    assert has_element?(view, "#product-sidebar-toggle[aria-expanded='true']")
    assert has_element?(view, "#product-sidebar-toggle[aria-label='Toggle sidebar']")

    view |> element("#product-sidebar-toggle") |> render_click()
    assert has_element?(view, "#product-sidebar[data-sidebar-state='rail']")
    assert has_element?(view, "#product-sidebar-toggle[aria-expanded='false']")
    # The expanded workspace sections give way to the rail (flyout on demand).
    refute has_element?(view, "#sidebar-workspace-sections")

    view |> element("#product-sidebar-toggle") |> render_click()
    assert has_element?(view, "#product-sidebar[data-sidebar-state='expanded']")
    assert has_element?(view, "#sidebar-workspace-sections")
  end

  test "full hide leaves the autofocused reopen tab as the surviving control", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jobs")

    refute has_element?(view, "#product-sidebar-reopen")

    render_hook_or_event(view, "toggle_sidebar_hidden")
    assert has_element?(view, "#product-sidebar[data-sidebar-state='hidden']")
    assert has_element?(view, "#product-sidebar-reopen[aria-label='Reopen navigation']")

    view |> element("#product-sidebar-reopen") |> render_click()
    assert has_element?(view, "#product-sidebar[data-sidebar-state='expanded']")
    refute has_element?(view, "#product-sidebar-reopen")
  end

  test "the LayoutPrefs restore path sets a valid persisted state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/objectives")

    # The hook pushes the persisted value on mount; simulate the restore.
    render_hook(view, "set_sidebar_state", %{"state" => "rail"})
    assert has_element?(view, "#product-sidebar[data-sidebar-state='rail']")

    # Invalid values are ignored (validated in SharedShellHooks).
    render_hook(view, "set_sidebar_state", %{"state" => "sideways"})
    assert has_element?(view, "#product-sidebar[data-sidebar-state='rail']")
  end

  test "the workspace rail flyout opens on click and closes on escape", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    view |> element("#product-sidebar-toggle") |> render_click()
    assert has_element?(view, "#product-sidebar[data-sidebar-state='rail']")

    # In rail mode the Workspace entry is a flyout button, not a navigate pill.
    assert has_element?(view, "#operator-nav-workspace[aria-haspopup='true']")
    refute has_element?(view, "#operator-rail-flyout")

    view |> element("#operator-nav-workspace") |> render_click()
    assert has_element?(view, "#operator-rail-flyout")
    assert has_element?(view, "#operator-rail-flyout #sidebar-workspace-sections")
    assert has_element?(view, "#operator-nav-workspace[aria-expanded='true']")

    # v0.61b M9.1 (ADR 0080 focus-return guardrail): the Escape binding is a JS
    # chain that pushes the close AND returns focus to the invoking rail icon
    # (click-away deliberately closes without stealing focus — APG pattern).
    wrap = render(element(view, ".operator-rail-flyout-wrap"))
    assert wrap =~ "close_rail_flyout"
    assert wrap =~ "focus"
    assert wrap =~ "#operator-nav-workspace"

    view
    |> element(".operator-rail-flyout-wrap")
    |> render_keydown(%{"key" => "escape"})

    refute has_element?(view, "#operator-rail-flyout")

    IO.puts(
      "sidebar-collapse-a11y-001 status=pass states=expanded+rail+hidden " <>
        "flyout=click_activated persistence=layout_prefs_localStorage default=expanded " <>
        "focus_return=escape_to_invoker"
    )
  end

  test "the LayoutPrefs hook is anchored to the sidebar and carries its JS contract", %{
    conn: conn
  } do
    # v0.61b M9.1 gate hardening: nothing previously asserted the hook
    # attachment — deleting phx-hook="LayoutPrefs" killed persistence restore
    # and all three shortcuts with a green gate.
    {:ok, view, _html} = live(conn, ~p"/jobs")
    assert has_element?(view, "#product-sidebar[phx-hook='LayoutPrefs']")

    js = File.read!(@js_path)
    assert js =~ ~s(const LayoutPrefs)
    assert js =~ ~s(allbert.sidebar.state.v1)
    assert js =~ ~s(cycle_sidebar_state)
    assert js =~ ~s(toggle_sidebar_hidden)
    assert js =~ ~s(set_sidebar_state)
    # The M9.1 focus-return listener for patch-replaced controls.
    assert js =~ ~s(phx:allbert:focus)
  end

  test "the collapse machinery is desktop-only and hidden nav is unfocusable" do
    css = File.read!(@css_path)

    assert css =~ ~s(#product-sidebar[data-sidebar-state="hidden"])
    assert Regex.match?(~r/\[data-sidebar-state="hidden"\]\s*\{\s*display:\s*none/, css)
    assert css =~ ~s(.workspace-with-sidebar[data-sidebar-state="rail"])
    assert css =~ ~s(.operator-shell[data-sidebar-state="rail"])
    assert css =~ "#product-sidebar-reopen"
    # Mobile keeps the overlay drawer; the desktop collapse controls hide.
    assert Regex.match?(
             ~r/@media \(max-width: 767\.98px\)\s*\{\s*#product-sidebar-reopen,\s*\.operator-sidebar-toggle\s*\{\s*display:\s*none/,
             css
           )
  end

  test "the browser-sweep flyout positioning fixes are guarded" do
    # v0.61b M9.1 gate hardening: these two rules were found broken manually in
    # the pre-operator browser sweep (flyout clipped by the sidebar scroll
    # container; then trapped by the nav-group animation's persistent fill
    # transform, which makes the group the fixed-position containing block).
    css = File.read!(@css_path)

    [flyout] =
      Regex.run(~r/\.operator-rail-flyout\s*\{(.*?)\n  \}/s, css, capture: :all_but_first)

    assert flyout =~ "position: fixed"

    assert Regex.match?(
             ~r/\.operator-nav-group\s*\{\s*animation-fill-mode:\s*backwards;\s*\}/,
             css
           )

    # The mobile launcher overlay's bottom bound needs the fallback — the
    # token is declared on #workspace-shell and the sidebar is its sibling.
    assert css =~ "var(--workspace-mobile-shellbar-space, 5.75rem)"
  end

  # The hidden toggle disappears with the sidebar, so drive the shared event
  # directly (the keyboard path LayoutPrefs uses).
  defp render_hook_or_event(view, event) do
    render_hook(view, event, %{})
  end
end
