defmodule AllbertAssistWeb.Workspace.ResponsiveTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  test "workspace stylesheet defines mobile and desktop workspace layouts" do
    css = File.read!(@css_path)

    assert css =~ "@media (min-width: 768px)"
    assert css =~ "@media (max-width: 767.98px)"
    assert css =~ "grid-template-areas:"
    # v0.61b M5: the workspace submenu column is retired — the root grid is
    # single-column ("nav chat" gone); the product sidebar owns navigation.
    refute css =~ ~s("nav chat")
    assert css =~ ~s(#workspace-shell[data-canvas-drawer="open"])
    # v0.61b M6 (ADR 0080 §3): the canvas is a docked resizable pane beside
    # chat — the two-pane grid and the col-resize divider are now REQUIRED
    # (this test previously refuted them while the canvas was a fixed drawer).
    assert css =~ ~s("chat resizer canvas")
    assert css =~ ~s(#workspace-shell[data-mobile-tab="canvas"] #workspace-node-workspace-chat)
    assert css =~ "#workspace-split-resizer"
    assert css =~ "cursor: col-resize"
    assert css =~ "position: sticky"
  end

  # v0.61b M7: the AppBar is retired (ADR 0080 §2) — the shell still
  # constrains to the viewport and the canvas region never overlays chat.
  test "the shell constrains to the viewport with no appbar chrome" do
    css = File.read!(@css_path)

    refute css =~ "#workspace-shell .allbert-appbar"
    assert css =~ ~r/#workspace-shell\.workspace-shell\s*\{[^}]*100dvh/m
    assert css =~ ~r/#workspace-shell\.workspace-shell\s*\{[^}]*display:\s*flex/m

    # v0.61b M6: the canvas region is a docked grid pane — hidden when the
    # pane is closed, but NEVER position: fixed over chat.
    refute css =~
             ~r/#workspace-shell #workspace-node-workspace-canvas-region\s*\{[^}]*position:\s*fixed/m

    assert css =~
             ~r/#workspace-shell #workspace-node-workspace-canvas-region\s*\{[^}]*display:\s*none/m
  end

  # v0.34 M6: the mobile shellbar participates in shell flow so it remains
  # reachable without overlaying the active pane.
  test "mobile shellbar stays in flow and panes account for chrome height" do
    css = File.read!(@css_path)

    assert css =~ ~r/@media \(max-width: 767\.98px\)/
    assert css =~ ~r/\.workspace-mobile-shellbar\s*\{[^}]*order:\s*3/m
    assert css =~ ~r/\.workspace-mobile-shellbar\s*\{[^}]*flex:\s*0 0 auto/m

    assert css =~
             ~r/\.workspace-chat-pane[^{}]*\.workspace-canvas-node\s*\{[^}]*max-height:\s*clamp\(18rem,\s*calc\(100dvh - 24rem\),\s*34rem\)/m
  end

  # v0.26a M29: the composer counter exists in the stylesheet so the warning
  # variant cannot regress to identical styling with the default state.
  test "composer counter has a near-limit warning treatment" do
    css = File.read!(@css_path)

    assert css =~ ".workspace-composer-counter"

    assert css =~
             ~r/\.workspace-composer-counter\[data-near-limit="true"\]\s*\{[^}]*color:\s*var\(--allbert-warn\)/m
  end
end
