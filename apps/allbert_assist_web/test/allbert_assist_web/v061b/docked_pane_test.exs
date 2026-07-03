defmodule AllbertAssistWeb.V061b.DockedPaneTest do
  @moduledoc """
  v0.61b M6 proof (feedback #1, ADR 0080 §3): the workspace canvas/tool region
  is a right-docked resizable split pane beside chat — no fixed overlay ever
  occludes chat. Pane tenancy is replace-and-restore (operator decision
  2026-07-02): the region shows exactly one of canvas content or one
  `workspace:*` destination panel; closing the destination restores the
  canvas. Width rides the shipped `WorkspaceSplitResizer`
  (`--workspace-chat-ratio`, localStorage-persisted, clamp 35–70).
  """
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :docked_pane

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  test "the canvas region is a docked grid pane, never a fixed overlay" do
    css = File.read!(@css_path)

    refute Regex.match?(
             ~r/#workspace-shell #workspace-node-workspace-canvas-region\s*\{[^}]*position:\s*fixed/m,
             css
           ),
           "the canvas region must not be a fixed overlay over chat"

    assert css =~ ~s("chat resizer canvas")
    assert css =~ ~s("chat resizer ephemeral")
    assert css =~ "cursor: col-resize"
    assert css =~ "--workspace-chat-ratio"
    assert css =~ "#workspace-canvas-reopen"
  end

  test "opening a destination docks the pane with chat still present", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:settings")

    assert has_element?(view, "#workspace-shell[data-canvas-drawer='open']")
    assert has_element?(view, "#workspace-node-workspace-canvas-region")
    assert has_element?(view, "#workspace-node-workspace-chat")
    assert has_element?(view, "#workspace-node-workspace-chat-composer")
    assert has_element?(view, "#workspace-split-resizer[phx-hook='WorkspaceSplitResizer']")
    assert has_element?(view, "#workspace-split-collapse")

    # v0.61b M9.1: the floating-drawer language retired with the presentation —
    # no live control or copy may still say "drawer" (the pane toggle said
    # "Open/Close canvas drawer" and the empty state pointed at "the canvas
    # drawer" until the audit).
    refute render(view) =~ "canvas drawer"
    assert render(view) =~ "canvas pane"

    IO.puts(
      "docked-panel-not-floating-001 status=pass overlay=none divider=WorkspaceSplitResizer " <>
        "persistence=split_ratio_localStorage chat=unoccluded"
    )
  end

  test "replace-and-restore tenancy round-trips tiles → panel → tiles", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    # Canvas content first (output), then a destination panel replaces it,
    # then selecting output restores the canvas.
    view |> element("#workspace-dest-output") |> render_click()
    assert has_element?(view, "#workspace-shell[data-canvas-destination='output']")
    assert has_element?(view, "#workspace-canvas[data-destination='output']")

    view |> element("#workspace-dest-workspace-settings") |> render_click()
    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:settings']")
    assert has_element?(view, "#workspace-canvas[data-destination='workspace:settings']")

    view |> element("#workspace-dest-output") |> render_click()
    assert has_element?(view, "#workspace-shell[data-canvas-destination='output']")
    assert has_element?(view, "#workspace-canvas[data-destination='output']")
  end

  test "the pane collapses and the slim reopen tab brings it back", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:settings")

    assert has_element?(view, "#workspace-shell[data-canvas-drawer='open']")

    view |> element("#workspace-split-collapse") |> render_click()
    assert has_element?(view, "#workspace-shell[data-canvas-drawer='closed']")
    assert has_element?(view, "#workspace-canvas-reopen[aria-expanded='false']")

    view |> element("#workspace-canvas-reopen") |> render_click()
    assert has_element?(view, "#workspace-shell[data-canvas-drawer='open']")
    assert has_element?(view, "#workspace-canvas-reopen[aria-expanded='true']")
  end
end
