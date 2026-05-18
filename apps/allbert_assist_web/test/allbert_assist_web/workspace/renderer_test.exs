defmodule AllbertAssistWeb.Workspace.RendererTest do
  use AllbertAssistWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Catalog
  alias AllbertAssistWeb.Workspace.Components.Chat
  alias AllbertAssistWeb.Workspace.Components.Placeholder
  alias AllbertAssistWeb.Workspace.Renderer

  test "dispatch covers every known catalog component" do
    assert Renderer.renderer_for(:chat) == Chat

    for component <- Catalog.known_components() -- [:chat] do
      assert Renderer.renderer_for(component) == Placeholder
    end
  end

  test "unknown components render through the placeholder" do
    html =
      render_component(Renderer,
        id: "unknown-renderer",
        node: %Node{id: "unknown-node", component: :invented, props: %{}}
      )

    assert html =~ "invented"
    assert html =~ "component not implemented"
  end
end
