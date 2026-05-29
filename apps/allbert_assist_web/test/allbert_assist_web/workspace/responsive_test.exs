defmodule AllbertAssistWeb.Workspace.ResponsiveTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  test "workspace stylesheet defines mobile and desktop workspace layouts" do
    css = File.read!(@css_path)

    assert css =~ "@media (min-width: 768px)"
    assert css =~ "@media (max-width: 767.98px)"
    assert css =~ "grid-template-areas:"
    assert css =~ ~s("nav chat resizer canvas")
    refute css =~ ~s("chat resizer canvas")
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

    assert css =~
             ~r/\.workspace-chat-pane[^{}]*\.workspace-canvas-node\s*\{[^}]*overflow:\s*hidden/m
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
