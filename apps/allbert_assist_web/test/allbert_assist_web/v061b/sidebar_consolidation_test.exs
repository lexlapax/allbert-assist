defmodule AllbertAssistWeb.V061b.SidebarConsolidationTest do
  @moduledoc """
  v0.61b M5 proof (feedback #6 + #3's submenu half, ADR 0080 §1): one product
  sidebar owns navigation — the workspace-local submenu column is retired and
  its sections (Conversations/Output/Apps/Workspace) nest under the sidebar's
  Workspace entry, auto-expanded + active-highlighted on `/workspace` and
  absent (collapsed to the plain pill) on operator surfaces, whose LiveViews
  have no workspace handlers (the guarded-controls rule). Reachability is
  proven against the ENUMERATED destination inventory — not before/after
  parity; the pre-M5 DOM no longer exists to compare against.
  """
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Theme.Layout
  alias AllbertAssist.Workspace.Catalog, as: WorkspaceCatalog

  @moduletag :sidebar_consolidation

  test "the workspace sections nest under the sidebar and the column is retired", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/workspace")

    # Consolidated sections inside the product sidebar.
    assert has_element?(view, "#product-sidebar #sidebar-workspace-sections")
    assert has_element?(view, "#sidebar-workspace-sections #workspace-launcher")
    assert html =~ "Conversations"

    # Retired submenu column DOM.
    refute has_element?(view, "#workspace-node-workspace-nav-rail")
    refute has_element?(view, "#workspace-component-workspace-thread-list")
    refute has_element?(view, "#workspace-component-workspace-app-launcher")

    # Active-destination highlighting follows the canvas destination.
    assert has_element?(view, "#workspace-dest-output[aria-pressed='true']")

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:settings")
    assert has_element?(view, "#workspace-dest-workspace-settings[aria-pressed='true']")
    assert has_element?(view, "#workspace-dest-output[aria-pressed='false']")
  end

  test "operator surfaces render the plain Workspace pill with no workspace controls", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/jobs")

    assert has_element?(view, "#product-sidebar")
    assert has_element?(view, "#operator-nav-workspace")
    refute has_element?(view, "#sidebar-workspace-sections")

    sidebar = render(element(view, "#product-sidebar"))
    refute sidebar =~ ~s(phx-click="select_destination")
    refute sidebar =~ ~s(phx-click="new_thread")
    refute sidebar =~ ~s(phx-click="switch_workspace_thread")
  end

  # The inventory sweep clicks every destination through the live shell; each
  # select_destination rebuilds the canvas (panel reads included), so the sweep
  # legitimately needs more than the default 60s.
  @tag timeout: 240_000
  test "every destination in the enumerated inventory is reachable and deep-linkable", %{
    conn: conn
  } do
    destinations =
      Layout.current(%{})
      |> Layout.launcher_destinations(WorkspaceCatalog.known_destinations(%{registered_apps: []}))

    # v0.61b M9.2: cardinality floor — the sweep derives its inventory from
    # the live code, so a destination dropped from launcher_destinations would
    # vanish from both the sidebar and the sweep at once. 19 is the M5
    # inventory; growth is fine, silent shrinkage is not.
    assert length(destinations) >= 19,
           "destination inventory shrank to #{length(destinations)} (M5 established 19)"

    {:ok, view, _html} = live(conn, ~p"/workspace")

    # One mount; every inventory entry has a sidebar control and its in-place
    # `select_destination` dispatch resolves (the M0-spec on-/workspace path).
    for destination <- destinations do
      assert has_element?(view, "#workspace-dest-#{destination.dom_id}"),
             "destination #{destination.id} has no sidebar entry"

      view
      |> element("#workspace-dest-#{destination.dom_id}")
      |> render_click()

      assert has_element?(
               view,
               "#workspace-shell[data-canvas-destination='#{destination.id}']"
             ),
             "selecting #{destination.id} from the sidebar did not resolve"
    end

    # Deep-link sample (fresh mounts are expensive; the resolver is shared).
    for destination_id <- ["workspace:settings", "workspace:models"] do
      {:ok, linked, _html} = live(conn, ~p"/workspace?destination=#{destination_id}")

      assert has_element?(
               linked,
               "#workspace-shell[data-canvas-destination='#{destination_id}']"
             ),
             "deep link ?destination=#{destination_id} did not resolve"
    end

    IO.puts(
      "single-sidebar-consolidation-001 status=pass sections=conversations+output+apps+workspace " <>
        "column=retired inventory=#{length(destinations)} deep_links=workspace_tools authority=none"
    )
  end
end
