defmodule AllbertAssistWeb.Skeleton.LayoutSystemProofTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssistWeb.Skeleton.LayoutSystemManifest

  @moduletag :v061_layout_system

  @app_css Path.expand("../../../assets/css/app.css", __DIR__)
  @visual_direction "c"

  test "each layout system renders all nine IA surfaces through the catalog/shell in Direction C",
       %{conn: conn} do
    systems = LayoutSystemManifest.systems()
    surfaces = LayoutSystemManifest.surfaces()

    assert length(systems) >= 3, "v0.61 M1 requires at least three divergent layout systems"
    assert length(surfaces) == 9, "v0.61 M1 renders each system across all nine IA surfaces"

    for system <- systems, surface <- surfaces do
      system_str = Atom.to_string(system)
      path = LayoutSystemManifest.preview_path(system, surface)
      {:ok, view, html} = live(conn, path)

      # Renders through the operator shell carrying this system's zone-composition delta
      # AND the chosen Direction C visual language.
      assert has_element?(
               view,
               "#v061-layout-shell" <>
                 "[data-layout-system='#{system_str}']" <>
                 "[data-visual-direction='#{@visual_direction}']"
             )

      assert has_element?(
               view,
               "#v061-layout-#{system_str}-#{surface}" <>
                 "[data-layout-system='#{system_str}']" <>
                 "[data-layout-surface='#{surface}']"
             )

      # No live data, no authority.
      assert html =~ ~s(data-skeleton-live-data="false")
      assert html =~ ~s(data-authority="none")
      assert html =~ ~s(data-settings-keys="0")

      # A11y readiness markers hold on every system × surface.
      assert html =~ ~s(data-keyboard-focus-ready="true")
      assert html =~ ~s(data-high-contrast-ready="true")
      assert html =~ ~s(data-reduced-motion-ready="true")

      # The catalog stays the rendering boundary.
      assert has_element?(view, "#v061-layout-surface-#{system_str}-#{surface}")
      assert has_element?(view, "[data-workspace-component='empty_state']")

      # No unknown-component fallback placeholder, no effectful affordance.
      refute html =~ "data-placeholder-component"
      refute html =~ "unknown workspace component"
      refute html =~ "Approve"
      refute html =~ "Promote"
      refute html =~ ~s(data-action-source="actions-runner")
    end

    IO.puts(
      "layout-systems-rendered-001 status=pass systems=#{length(systems)} " <>
        "surfaces_per_system=#{length(surfaces)} visual_direction=#{@visual_direction} " <>
        "live_data=false authority=none"
    )
  end

  test "surface_paths enumerates every system x nine-surface preview path" do
    systems = LayoutSystemManifest.systems()
    surfaces = LayoutSystemManifest.surfaces()

    assert length(LayoutSystemManifest.surface_paths()) == length(systems) * length(surfaces)

    for system <- systems, surface <- surfaces do
      assert LayoutSystemManifest.preview_path(system, surface) in LayoutSystemManifest.surface_paths()
    end
  end

  test "each layout system carries a distinct zone-composition delta in app.css" do
    css = File.read!(@app_css)

    for system <- LayoutSystemManifest.systems() do
      assert css =~ ~s(.operator-shell[data-layout-system="#{system}"]),
             "missing CSS layout block for system #{system}"
    end
  end
end
