defmodule AllbertAssistWeb.Workspace.ResponsiveTest do
  use ExUnit.Case, async: true

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  test "workspace stylesheet defines mobile and desktop workspace layouts" do
    css = File.read!(@css_path)

    assert css =~ "@media (min-width: 768px)"
    assert css =~ "@media (max-width: 767.98px)"
    assert css =~ "grid-template-areas:"
    assert css =~ ~s("chat resizer canvas")
    assert css =~ ~s(#workspace-shell[data-mobile-tab="canvas"] #workspace-node-workspace-chat)
    assert css =~ "--workspace-chat-ratio"
    assert css =~ "#workspace-split-resizer"
    assert css =~ "cursor: col-resize"
    assert css =~ "min-height: 44px"
    assert css =~ "position: sticky"
  end

  # v0.26a M30: the AppBar is anchored so chat history scrolling does not
  # take the workspace chrome with it.
  test "AppBar is sticky and the workspace shell constrains to the viewport" do
    css = File.read!(@css_path)

    assert css =~ "#workspace-shell .allbert-appbar"
    assert css =~ ~r/#workspace-shell\.workspace-shell\s*\{[^}]*100dvh/m
    assert css =~ ~r/#workspace-shell\.workspace-shell\s*\{[^}]*display:\s*flex/m
    assert css =~ ~r/\.workspace-chat-pane[^{}]*\.workspace-canvas-node\s*\{[^}]*overflow:\s*hidden/m
  end

  # v0.26a M31: the mobile tab strip stays accessible just below the
  # sticky AppBar and the active pane fills the remaining viewport.
  test "mobile tab strip is sticky and panes account for chrome height" do
    css = File.read!(@css_path)

    assert css =~ ~r/@media \(max-width: 767\.98px\)/
    assert css =~ ~r/#workspace-mobile-tabs\s*\{[^}]*position:\s*sticky/m
    assert css =~ ~r/\.workspace-chat-pane[^{}]*\.workspace-canvas-node\s*\{[^}]*max-height:\s*calc\(100dvh - 9rem\)/m
  end

  # v0.26a M29: the composer counter exists in the stylesheet so the warning
  # variant cannot regress to identical styling with the default state.
  test "composer counter has a near-limit warning treatment" do
    css = File.read!(@css_path)

    assert css =~ ".workspace-composer-counter"
    assert css =~ ~r/\.workspace-composer-counter\[data-near-limit="true"\]\s*\{[^}]*color:\s*var\(--allbert-warn\)/m
  end
end
