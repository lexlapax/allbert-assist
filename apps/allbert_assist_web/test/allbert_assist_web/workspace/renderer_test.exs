defmodule AllbertAssistWeb.Workspace.RendererTest do
  use AllbertAssistWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Catalog
  alias AllbertAssistWeb.Workspace.Components.Placeholder
  alias AllbertAssistWeb.Workspace.Renderer

  test "dispatch covers every known catalog component" do
    for component <- Catalog.known_components() do
      assert Renderer.renderer_for(component) != Placeholder
    end
  end

  test "every known component renders non-empty output" do
    for component <- Catalog.known_components() do
      html =
        render_component(Renderer,
          id: "renderer-#{component}",
          node: %Node{
            id: "node-#{component}",
            component: component,
            props: sample_props(component)
          },
          renderer_context: renderer_context(),
          workspace_state: workspace_state()
        )

      assert html =~ ~s(data-workspace-component="#{component}")
      refute html =~ "component not implemented"

      if component in [:analysis_card, :agent_report_card, :parity_card, :debate_round_card] do
        assert html =~ "stub"
      end
    end
  end

  test "unknown components render through the safe fallback" do
    html =
      render_component(Renderer,
        id: "unknown-renderer",
        node: %Node{id: "unknown-node", component: :invented, props: %{}}
      )

    assert Renderer.renderer_for(:invented) == Placeholder
    assert html =~ "invented"
    assert html =~ "unknown workspace component"
    refute html =~ "component not implemented"
  end

  defp sample_props(:header), do: %{title: "Workspace Header", subtitle: "Subheading"}
  defp sample_props(:empty_state), do: %{title: "Empty", body: "Nothing to render yet."}
  defp sample_props(:link), do: %{label: "Open trace", body: "/trace/example"}
  defp sample_props(:status_badge), do: %{label: "Status", value: "ready"}
  defp sample_props(_component), do: %{title: "Renderer sample", body: "Rendered output"}

  defp renderer_context do
    %{
      active_objectives: [%{id: "obj-1", status: "running", title: "Sample objective"}],
      canvas_tiles: [%{id: "tile-1"}],
      ephemeral_surfaces: [%{id: "surface-1"}]
    }
  end

  defp workspace_state do
    %{
      prompt: "Hello Allbert",
      response: nil,
      asking?: false,
      approval_lines: []
    }
  end
end
