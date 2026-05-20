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

  test "tile and ephemeral nodes expose semantic accessibility roles" do
    tile_html =
      render_component(Renderer,
        id: "tile-renderer",
        node: %Node{
          id: "tile-1",
          component: :tile,
          props: %{title: "Decision summary", body: "Pinned result"}
        }
      )

    assert tile_html =~ ~s(role="article")
    assert tile_html =~ ~s(aria-labelledby="workspace-component-title-tile-1")
    assert tile_html =~ ~s(id="workspace-component-title-tile-1")

    ephemeral_html =
      render_component(Renderer,
        id: "ephemeral-renderer",
        node: %Node{
          id: "approval-surface-1",
          component: :ephemeral_surface,
          props: %{title: "Approval surface", body: "Needs confirmation"},
          children: [
            %Node{id: "approval-card-1", component: :approval_card, props: %{title: "Approve"}}
          ]
        }
      )

    assert ephemeral_html =~ ~s(role="dialog")
    assert ephemeral_html =~ ~s(aria-modal="true")
    assert ephemeral_html =~ ~s(phx-hook="FocusTrap")
    assert ephemeral_html =~ ~s(aria-labelledby="workspace-component-title-approval-surface-1")
    assert ephemeral_html =~ ~s(id="workspace-component-title-approval-surface-1")
  end

  test "tile with semantic child card does not expose raw tile body" do
    html =
      render_component(Renderer,
        id: "objective-tile-renderer",
        node: %Node{
          id: "objective-tile",
          component: :tile,
          props: %{
            title: "Objective Progress",
            body: "kind=objective_card",
            tile_kind: "objective_card"
          },
          children: [
            %Node{
              id: "objective-card",
              component: :objective_card,
              props: %{
                title: "Analyze AAPL",
                body: "Complete a StockSage analysis for AAPL."
              }
            }
          ]
        },
        renderer_context: renderer_context(),
        workspace_state: workspace_state()
      )

    assert html =~ "Objective Progress"
    assert html =~ "Analyze AAPL"
    refute html =~ "workspace-tile-readonly"
    refute html =~ "kind=objective_card"
  end

  test "editable text tile keeps only editor body under phx-update ignore" do
    html =
      render_component(Renderer,
        id: "editable-tile-renderer",
        node: %Node{
          id: "canvas-tile-editable",
          component: :tile,
          props: %{
            title: "Notes",
            tile_id: "tile-editable",
            tile_kind: "markdown",
            tile_text: "offline notes",
            editable?: true
          }
        },
        renderer_context:
          Map.merge(renderer_context(), %{
            user_id: "local",
            thread_id: "thread-1",
            workspace_offline_enabled?: true,
            workspace_indexeddb_quota_bytes: 1024
          }),
        workspace_state: workspace_state()
      )

    assert html =~ ~s(data-workspace-component="tile")
    assert html =~ ~s(id="workspace-tile-editor-tile-editable")
    assert html =~ ~s(phx-hook="WorkspaceTileEditor")
    assert html =~ ~s(phx-update="ignore")
    assert html =~ ~s(data-quota-bytes="1024")
    assert html =~ "offline notes"
    assert html =~ ~s(id="workspace-tile-action-tile-editable")
    assert html =~ ~s(phx-click="manage_workspace_tile")
    assert html =~ ~s(phx-value-operation="pin")
    assert html =~ ~s(id="workspace-tile-menu-button-tile-editable")
    refute html =~ ~s(id="workspace-tile-action-tile-editable" disabled)
  end

  test "tile renderer opens operator action menu from renderer context" do
    html =
      render_component(Renderer,
        id: "tile-menu-renderer",
        node: %Node{
          id: "canvas-tile-menu",
          component: :tile,
          props: %{
            title: "Analysis",
            body: "kind=analysis_card",
            tile_id: "tile-menu",
            tile_kind: "analysis_card",
            pinned?: true
          }
        },
        renderer_context:
          Map.merge(renderer_context(), %{
            open_tile_menu_id: "tile-menu"
          }),
        workspace_state: workspace_state()
      )

    assert html =~ ~s(id="workspace-tile-menu-tile-menu")
    assert html =~ ~s(role="menu")
    assert html =~ "Unpin tile"
    assert html =~ "Remove tile"
    assert html =~ ~s(phx-value-operation="remove")
  end

  test "tile renderer exposes offline conflict revert affordance" do
    html =
      render_component(Renderer,
        id: "conflict-tile-renderer",
        node: %Node{
          id: "canvas-tile-conflict",
          component: :tile,
          props: %{
            title: "Notes",
            tile_id: "tile-conflict",
            tile_kind: "text",
            tile_text: "stale offline notes",
            editable?: true,
            conflict_summary: %{
              conflict?: true,
              conflict_count: 2,
              revert_revision_id: "rev-before-conflict"
            }
          }
        },
        renderer_context:
          Map.merge(renderer_context(), %{
            user_id: "local",
            thread_id: "thread-1",
            workspace_offline_enabled?: true
          }),
        workspace_state: workspace_state()
      )

    assert html =~ ~s(data-workspace-conflict-banner="true")
    assert html =~ "2 offline edit(s) were merged"
    assert html =~ ~s(phx-click="revert_tile_revision")
    assert html =~ ~s(phx-value-revision-id="rev-before-conflict")
  end

  test "tabs render accessible tablist, tabs, and panels" do
    html =
      render_component(Renderer,
        id: "tabs-renderer",
        node: %Node{
          id: "tabs-1",
          component: :tabs,
          props: %{title: "Inspector tabs"},
          children: [
            %Node{
              id: "tab-overview",
              component: :tab,
              props: %{
                title: "Overview",
                selected?: true,
                panel_id: "workspace-component-panel-overview"
              }
            },
            %Node{
              id: "panel-overview",
              component: :tab_panel,
              props: %{title: "Overview panel", tab_id: "workspace-component-tab-overview"}
            }
          ]
        },
        renderer_context: renderer_context(),
        workspace_state: workspace_state()
      )

    assert html =~ ~s(role="tablist")
    assert html =~ ~s(phx-hook="WorkspaceTabs")
    assert html =~ ~s(role="tab")
    assert html =~ ~s(aria-selected="true")
    assert html =~ ~s(role="tabpanel")
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
