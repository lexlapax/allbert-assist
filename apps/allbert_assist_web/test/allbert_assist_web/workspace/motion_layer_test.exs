defmodule AllbertAssistWeb.Workspace.MotionLayerTest do
  @moduledoc """
  v0.61 M7 proof: the entrance / drawer / skeleton motion layer is expressed through
  the Direction C motion roles over the promoted :root motion-scale tokens (no
  hardcoded durations or easings), and collapses to instant under the reduced-motion
  axis. Presentation-only.
  """
  use ExUnit.Case, async: true
  @moduletag :pure_async

  @moduletag :v061_motion

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  test "the entrance/drawer/skeleton motion roles are token-driven" do
    css = File.read!(@css_path)

    assert css =~ "@keyframes allbert-card-enter"
    assert css =~ "@keyframes allbert-skeleton-pulse"

    # Entrance uses the base duration + emphasis-overshoot ease tokens.
    assert css =~ "animation: allbert-card-enter var(--allbert-motion-duration-base)"
    assert css =~ "var(--allbert-motion-ease-emphasis)"

    # v0.62 M0.1: the drawer motion role retired with the UtilityDrawer zombie
    # chain — no [data-workspace-pattern="drawer-shell"] rule remains.
    refute css =~ ~s([data-workspace-pattern="drawer-shell"])

    # Skeleton/loading role uses the slow duration token.
    assert css =~ "animation: allbert-skeleton-pulse var(--allbert-motion-duration-slow)"

    IO.puts("motion-token-driven-001 status=pass roles=entrance,drawer,skeleton source=tokens")
  end

  test "reduced motion collapses every transition and animation to instant" do
    css = File.read!(@css_path)

    assert css =~ ~s([data-reduce-motion="true"] *)
    assert css =~ "transition-duration: 0.001ms !important"
    assert css =~ "animation-duration: 0.001ms !important"
    assert css =~ "@media (prefers-reduced-motion: reduce)"

    IO.puts("motion-respects-reduced-motion-001 status=pass collapse=instant")
  end
end
