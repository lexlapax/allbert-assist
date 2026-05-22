defmodule AllbertAssistWeb.Workspace.Components.TileInspectorTest do
  use AllbertAssistWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias AllbertAssist.Workspace.Canvas.Tile
  alias AllbertAssistWeb.Workspace.Components.TileInspector

  test "renders body, provenance, trace link, and copy affordances" do
    tile = %Tile{
      id: "tile_inspector_fixture",
      user_id: "local",
      thread_id: "thr_inspector",
      kind: "analysis_card",
      body_yaml_path: "workspace/canvas/local/thr_inspector/tile.yml",
      current_revision_id: "rev_123",
      metadata: %{"emitter_id" => "AllbertAssist.TestEmitter"},
      body: %{
        surface: %{
          label: "Inspection fixture",
          nodes: [
            %{
              component: :trace_link,
              props: %{href: "/traces/trace_123", body: "trace_123"}
            }
          ]
        },
        fragment: %{
          emitter_id: "AllbertAssist.FragmentEmitter",
          emitted_at: "2026-05-22T00:00:00Z",
          scope: :canvas
        },
        text: "Full tile body for inspector tests"
      }
    }

    html = render_component(TileInspector, id: "tile-inspector-test", tile: tile)

    assert html =~ ~s(id="workspace-tile-inspector")
    assert html =~ ~s(role="dialog")
    assert html =~ ~s(phx-hook="FocusTrap")
    assert html =~ "Inspection fixture"
    assert html =~ "Full tile body for inspector tests"
    assert html =~ "AllbertAssist.FragmentEmitter"
    assert html =~ ~s(id="workspace-tile-inspector-trace-link")
    assert html =~ ~s(href="/traces/trace_123")
    assert html =~ ~s(id="workspace-tile-inspector-copy-id")
    assert html =~ ~s(data-copy-value="tile_inspector_fixture")
    assert html =~ ~s(id="workspace-tile-inspector-copy-body")
  end
end
