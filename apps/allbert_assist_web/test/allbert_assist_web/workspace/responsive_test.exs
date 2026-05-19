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
end
