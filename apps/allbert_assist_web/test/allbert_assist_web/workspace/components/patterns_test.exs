defmodule AllbertAssistWeb.Workspace.Components.PatternsTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Surface.Node
  alias AllbertAssistWeb.Workspace.Components.Patterns
  alias AllbertAssistWeb.Workspace.Renderer

  defmodule ModalHost do
    use Phoenix.Component

    alias AllbertAssistWeb.Workspace.Components.Patterns

    def render(assigns) do
      ~H"""
      <Patterns.workspace_modal
        id="test-modal"
        labelledby="test-modal-title"
        describedby="test-modal-summary"
        dismiss_event="close_test_modal"
        click_away={true}
      >
        <h2 id="test-modal-title">Shared modal</h2>
        <p id="test-modal-summary">Reusable modal body.</p>
      </Patterns.workspace_modal>
      """
    end
  end

  defmodule PatternHost do
    use Phoenix.Component

    alias AllbertAssistWeb.Workspace.Components.Patterns

    def render(assigns) do
      ~H"""
      <Patterns.status_callout id="test-status" title="Saved" message="The setting was saved." />
      <Patterns.error_callout id="test-error" title="Denied" message="The action was denied." />
      <Patterns.loading_state id="test-loading" label="Loading panel" detail="Fetching rows." />
      <Patterns.drawer_shell
        id="test-drawer"
        title="Canvas"
        summary="Workspace drawer"
        data-workspace-component="utility_drawer"
      >
        <p>Drawer body</p>
      </Patterns.drawer_shell>
      <Patterns.table_list
        id="test-table"
        title="Rows"
        summary="Bounded rows."
        row_count={2}
        max_rows={10}
      >
        <Patterns.table_row id="test-row" body="Row one" />
        <Patterns.table_column id="test-column" body="Column one" />
      </Patterns.table_list>
      """
    end
  end

  test "catalog buttons select variants from props" do
    danger_html =
      render_component(Renderer,
        id: "danger-button-renderer",
        node: %Node{
          id: "danger-button",
          component: :button,
          props: %{title: "Delete", variant: "danger"}
        }
      )

    assert danger_html =~ ~s(class="workspace-button workspace-button-danger")
    refute danger_html =~ "workspace-button-secondary"

    secondary_action_html =
      render_component(Renderer,
        id: "secondary-action-renderer",
        node: %Node{
          id: "secondary-action",
          component: :action_button,
          props: %{title: "Review", variant: "secondary"}
        }
      )

    assert secondary_action_html =~ ~s(class="workspace-button workspace-button-secondary")
    refute secondary_action_html =~ "workspace-button-primary"
  end

  test "compact button helper stays behind the variant registry" do
    assert Patterns.compact_button_class!("primary") == [
             "workspace-button workspace-button-primary",
             "workspace-button-compact"
           ]
  end

  test "nil button variant falls back to the default variant" do
    assert Patterns.button_class!(nil) == ["workspace-button workspace-button-primary", nil]
  end

  test "drawer and table contract helpers expose root-safe attrs" do
    assert Patterns.drawer_shell_class(retired?: true) == [
             "workspace-utility-drawer-shell",
             "workspace-utility-drawer-retired",
             nil
           ]

    assert Patterns.drawer_shell_attrs(
             title_id: "drawer-title",
             open?: false,
             retired?: true,
             hidden?: true
           ) == [
             {"hidden", true},
             {"data-workspace-pattern", "drawer-shell"},
             {"data-state", "closed"},
             {"data-retired", "true"},
             {"aria-labelledby", "drawer-title"},
             {"aria-hidden", "true"}
           ]

    assert Patterns.table_list_class("extra") == ["workspace-table-shell", "extra"]

    assert Patterns.table_list_attrs(title_id: "table-title", row_count: nil, max_rows: 10) == [
             {"data-workspace-pattern", "table-list"},
             {"data-max-rows", 10},
             {"aria-labelledby", "table-title"}
           ]

    assert Patterns.table_row_class("selected") == ["workspace-table-row", "selected"]
    assert Patterns.table_row_attrs() == [{"data-workspace-pattern", "table-row"}]
    assert Patterns.table_column_class() == ["workspace-table-column", nil]
    assert Patterns.table_column_attrs() == [{"data-workspace-pattern", "table-column"}]
  end

  test "status badge selects tone from props" do
    html =
      render_component(Renderer,
        id: "warning-status-renderer",
        node: %Node{
          id: "warning-status",
          component: :status_badge,
          props: %{body: "Needs review", tone: "warning"}
        }
      )

    assert html =~ ~s(class="workspace-status-pill workspace-status-warn")
    assert html =~ "Needs review"
  end

  test "unknown explicit variants fail fast" do
    assert_raise ArgumentError, ~r/unknown workspace button variant/, fn ->
      render_component(Renderer,
        id: "bad-button-renderer",
        node: %Node{
          id: "bad-button",
          component: :button,
          props: %{title: "Mystery", variant: "ghost"}
        }
      )
    end

    assert_raise ArgumentError, ~r/unknown workspace status tone/, fn ->
      render_component(Renderer,
        id: "bad-status-renderer",
        node: %Node{
          id: "bad-status",
          component: :status_badge,
          props: %{body: "Mystery", tone: "ghost"}
        }
      )
    end
  end

  test "shared modal pattern carries dialog semantics and focus handling" do
    html = render_component(&ModalHost.render/1, %{})

    assert html =~ ~s(data-workspace-pattern="modal")
    assert html =~ ~s(id="test-modal")
    assert html =~ ~s(role="dialog")
    assert html =~ ~s(aria-modal="true")
    assert html =~ ~s(aria-labelledby="test-modal-title")
    assert html =~ ~s(aria-describedby="test-modal-summary")
    assert html =~ ~s(phx-hook="FocusTrap")
    assert html =~ ~s(phx-click-away="close_test_modal")
    assert html =~ ~s(phx-window-keydown="close_test_modal")
    assert html =~ ~s(phx-key="escape")
  end

  test "shared callout, loading, drawer, and table/list patterns expose stable semantics" do
    html = render_component(&PatternHost.render/1, %{})

    assert html =~ ~s(id="test-status")
    assert html =~ ~s(data-workspace-pattern="status-callout")
    assert html =~ ~s(role="status")
    assert html =~ "The setting was saved."

    assert html =~ ~s(id="test-error")
    assert html =~ ~s(data-workspace-pattern="error-callout")
    assert html =~ ~s(role="alert")

    assert html =~ ~s(id="test-loading")
    assert html =~ ~s(data-workspace-pattern="loading-state")
    assert html =~ ~s(aria-busy="true")

    assert html =~ ~s(id="test-drawer")
    assert html =~ ~s(data-workspace-pattern="drawer-shell")
    assert html =~ ~s(data-state="open")
    assert html =~ ~s(data-workspace-component="utility_drawer")

    assert html =~ ~s(id="test-table")
    assert html =~ ~s(data-workspace-pattern="table-list")
    assert html =~ ~s(data-row-count="2")
    assert html =~ ~s(data-max-rows="10")
    assert html =~ ~s(data-workspace-pattern="table-row")
    assert html =~ ~s(data-workspace-pattern="table-column")
  end
end
