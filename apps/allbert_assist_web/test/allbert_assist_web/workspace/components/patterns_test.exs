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
end
