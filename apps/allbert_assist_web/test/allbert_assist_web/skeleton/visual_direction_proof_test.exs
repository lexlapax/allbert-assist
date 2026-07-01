defmodule AllbertAssistWeb.Skeleton.VisualDirectionProofTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssistWeb.Skeleton.VisualDirectionManifest

  @moduletag :v060b_visual_direction

  @app_css Path.expand(
             "../../../assets/css/app.css",
             __DIR__
           )

  test "each candidate direction renders the four hero screens through the catalog/shell",
       %{conn: conn} do
    directions = VisualDirectionManifest.directions()
    screens = VisualDirectionManifest.hero_screens()

    assert length(directions) >= 3,
           "v0.60b requires at least three divergent candidate directions"

    assert screens == [:workspace, :onboarding, :trust, :launch]

    for direction <- directions, screen <- screens do
      direction_str = Atom.to_string(direction)
      path = VisualDirectionManifest.preview_path(direction, screen)
      {:ok, view, html} = live(conn, path)

      # Renders through the operator shell carrying this direction's delta attribute.
      assert has_element?(
               view,
               "#v060b-visual-shell[data-visual-direction='#{direction_str}']"
             )

      assert has_element?(
               view,
               "#v060b-visual-#{direction_str}-#{screen}" <>
                 "[data-visual-direction='#{direction_str}']" <>
                 "[data-visual-screen='#{screen}']"
             )

      # No live data, no authority.
      assert html =~ ~s(data-skeleton-live-data="false")
      assert html =~ ~s(data-authority="none")
      assert html =~ ~s(data-settings-keys="0")

      # A11y readiness markers hold on every direction × screen.
      assert html =~ ~s(data-keyboard-focus-ready="true")
      assert html =~ ~s(data-high-contrast-ready="true")
      assert html =~ ~s(data-reduced-motion-ready="true")

      # The catalog stays the rendering boundary: the shared surface renders through
      # the workspace renderer with the same known catalog atoms as the skeleton.
      assert has_element?(view, "#v060b-visual-surface-#{direction_str}-#{screen}")
      assert has_element?(view, "[data-workspace-component='empty_state']")
      assert has_element?(view, "[data-workspace-component='status_badge']")

      if screen == :launch do
        assert has_element?(view, "button[disabled]")
      end

      # No unknown-component fallback placeholder, no effectful affordance.
      refute html =~ "data-placeholder-component"
      refute html =~ "unknown workspace component"
      refute html =~ "Approve"
      refute html =~ "Promote"
      refute html =~ ~s(data-action-source="actions-runner")
    end

    IO.puts(
      "hero-renderings-present-001 status=pass directions=#{length(directions)} " <>
        "hero_screens_per_direction=#{length(screens)} live_data=false authority=none"
    )
  end

  test "the selected-direction proof renders the four hero screens as the chosen direction",
       %{conn: conn} do
    chosen = Atom.to_string(VisualDirectionManifest.chosen_direction())
    screens = VisualDirectionManifest.hero_screens()

    for screen <- screens do
      path = VisualDirectionManifest.preview_path(:selected, screen)
      {:ok, view, html} = live(conn, path)

      # The proof renders as the M5-chosen direction (not a fourth one).
      assert has_element?(view, "#v060b-visual-shell[data-visual-direction='#{chosen}']")

      assert has_element?(
               view,
               "#v060b-visual-selected-#{screen}" <>
                 "[data-selected-proof='true']" <>
                 "[data-visual-requested='selected']" <>
                 "[data-visual-direction='#{chosen}']"
             )

      # A11y axes hold + no live data / no authority on the proof.
      assert html =~ ~s(data-keyboard-focus-ready="true")
      assert html =~ ~s(data-high-contrast-ready="true")
      assert html =~ ~s(data-reduced-motion-ready="true")
      assert html =~ ~s(data-skeleton-live-data="false")
      assert html =~ ~s(data-authority="none")

      assert has_element?(view, "#v060b-visual-surface-selected-#{screen}")
      refute html =~ "data-placeholder-component"
      refute html =~ "unknown workspace component"
      refute html =~ "Approve"
      refute html =~ "Promote"
      refute html =~ ~s(data-action-source="actions-runner")
    end

    IO.puts(
      "styled-skeleton-proof-001 status=pass direction=#{chosen} " <>
        "hero_screens=#{length(screens)} a11y=pass live_data=false authority=none"
    )
  end

  test "hero_paths enumerates every candidate direction x hero screen" do
    directions = VisualDirectionManifest.directions()
    screens = VisualDirectionManifest.hero_screens()

    assert length(VisualDirectionManifest.hero_paths()) == length(directions) * length(screens)

    for direction <- directions, screen <- screens do
      assert VisualDirectionManifest.preview_path(direction, screen) in VisualDirectionManifest.hero_paths()
    end
  end

  test "each direction carries a distinct token/theme delta in app.css" do
    css = File.read!(@app_css)

    for direction <- VisualDirectionManifest.directions() do
      assert css =~ ~s([data-visual-direction="#{direction}"]),
             "missing CSS delta block for direction #{direction}"
    end

    # The directions must diverge on their distinguishing tokens, not be re-skins:
    # extract each direction's --allbert-font-family and assert all three differ.
    fonts = Enum.map(VisualDirectionManifest.directions(), &direction_font(css, &1))

    assert length(Enum.uniq(fonts)) == length(fonts),
           "directions share a type family: #{inspect(fonts)}"
  end

  # Grabs the --allbert-font-family declared in the base `[data-visual-direction="x"]`
  # block (the first occurrence), as a coarse divergence fingerprint.
  defp direction_font(css, direction) do
    [_, tail] = String.split(css, ~s([data-visual-direction="#{direction}"] {), parts: 2)
    [block, _] = String.split(tail, "}", parts: 2)

    block
    |> String.split("\n")
    |> Enum.find(&String.contains?(&1, "--allbert-font-family"))
    |> to_string()
    |> String.trim()
  end
end
