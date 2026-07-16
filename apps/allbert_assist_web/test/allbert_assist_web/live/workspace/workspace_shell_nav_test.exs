defmodule AllbertAssistWeb.WorkspaceShellNavTest do
  use AllbertAssistWeb.ConnCase, async: false
  use AllbertAssistWeb.WorkspaceLiveCase

  import Phoenix.LiveViewTest

  alias AllbertAssist.{Conversations, Objectives, Paths, Settings}

  test "old operator home routes are absent", %{conn: conn} do
    for path <- ["/agent", "/settings"] do
      conn = conn |> recycle() |> get(path)
      assert html_response(conn, 404) == "Not Found"
    end
  end

  test "mount renders workspace shell, chat fallback, and empty canvas placeholder", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    assert has_element?(view, "#workspace-shell")

    assert has_element?(
             view,
             "#workspace-shell[data-user-id='local'][data-thread-id='#{thread_id}']"
           )

    assert has_element?(view, "#workspace-shell[data-layout-mode='chat-primary']")
    assert has_element?(view, "#workspace-shell[data-canvas-drawer='closed']")
    assert has_element?(view, "#workspace-renderer")
    # v0.61b M7 (ADR 0080 §2): the appbar is retired.
    refute has_element?(view, "#allbert-appbar")
    # v0.61b M5 (ADR 0080 §1): the workspace-local submenu column is retired;
    # its sections nest under the product sidebar's Workspace entry.
    refute has_element?(view, "#workspace-node-workspace-nav-rail")
    refute has_element?(view, "#workspace-component-workspace-thread-list")
    refute has_element?(view, "#workspace-component-workspace-app-launcher")
    assert has_element?(view, "#sidebar-workspace-sections")
    assert has_element?(view, "#workspace-launcher")
    assert html =~ "Conversations"
    refute has_element?(view, "#workspace-node-workspace-utility-drawer")
    refute has_element?(view, "#workspace-node-workspace-objectives")

    assert has_element?(
             view,
             "#workspace-context-indicator[data-active-app='allbert']",
             "Neutral"
           )

    refute has_element?(view, "#workspace-context-exit")
    # v0.61b M7: the appbar thread switcher and tile-count chip are retired
    # (relocation rows 3/7) — the sidebar Conversations section switches
    # threads; the pane header's tiles badge is the single tile count.
    refute has_element?(view, "#workspace-thread-switcher-toggle")
    refute has_element?(view, "#workspace-tile-count-chip")
    assert has_element?(view, "#workspace-chat-region")

    assert has_element?(
             view,
             "#workspace-chat-canvas-toggle[aria-controls='workspace-node-workspace-canvas-region'][aria-expanded='false']"
           )

    assert has_element?(view, "#agent-form")

    assert has_element?(
             view,
             "#agent-prompt[placeholder='Ask Allbert anything…']"
           )

    refute html =~ "Prompt draft"
    refute html =~ ~r/<textarea[^>]*>\s*Hello Allbert/

    assert has_element?(
             view,
             "#workspace-split-resizer[role='separator'][aria-orientation='vertical']"
           )

    assert has_element?(view, "#workspace-node-workspace-canvas-region")
    assert has_element?(view, "#workspace-canvas[data-destination='output']")
    assert has_element?(view, "#workspace-canvas-cap-chip")
    assert has_element?(view, "#workspace-shell[data-canvas-destination='output']")
    assert has_element?(view, "#workspace-dest-workspace-discover")
    assert html =~ "canvas"
    refute html =~ "Workspace shell"
    refute html =~ "Prompt composer"
    refute html =~ "Runtime response timeline"
    refute html =~ "component not implemented"

    view
    |> element("#workspace-chat-canvas-toggle")
    |> render_click()

    assert render(view) =~ ~s(data-canvas-drawer="open")
  end

  test "mount applies workspace theme from settings", %{conn: conn} do
    assert {:ok, _setting} = Settings.put("workspace.theme.mode", "dark", %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/workspace")

    assert has_element?(view, "#workspace-shell[data-theme='dark']")
  end

  test "workspace theme toggle persists dark mode across reload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    subscribe_actions()

    assert has_element?(
             view,
             "#workspace-theme-toggle[data-current-theme='system'][data-next-theme='dark']"
           )

    html =
      view
      |> element("#workspace-theme-toggle")
      |> render_click()

    assert html =~ ~s(data-workspace-theme="dark")
    action_signal = receive_action_completed("set_workspace_theme")
    assert action_signal.data.status == :completed
    assert action_signal.data.permission_decision.permission == :settings_write
    assert {:ok, "dark"} = Settings.get("workspace.theme.mode")
    assert has_element?(view, "#workspace-shell[data-theme='dark'][data-workspace-theme='dark']")

    assert has_element?(
             view,
             "#workspace-theme-toggle[data-current-theme='dark'][data-next-theme='light']"
           )

    {:ok, reloaded, _html} = live(conn, ~p"/workspace")
    assert has_element?(reloaded, "#workspace-shell[data-theme='dark']")
  end

  test "workspace mobile tab toggle switches active section", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    assert has_element?(view, "#workspace-shell[data-mobile-tab='chat']")
    assert has_element?(view, "#workspace-shell[data-launcher-open='false']")
    assert has_element?(view, "#workspace-mobile-shellbar")
    assert has_element?(view, "#workspace-launcher-toggle[aria-expanded='false']")
    assert has_element?(view, "#workspace-mobile-tabs[role='tablist']")
    refute has_element?(view, "#workspace-mobile-tab-nav")
    assert has_element?(view, "#workspace-mobile-tab-chat[aria-selected='true']")
    assert has_element?(view, "#workspace-mobile-tab-canvas[aria-selected='false']")

    html =
      view
      |> element("#workspace-mobile-tab-canvas")
      |> render_click()

    assert html =~ ~s(data-mobile-tab="canvas")
    assert has_element?(view, "#workspace-mobile-tab-chat[aria-selected='false']")
    assert has_element?(view, "#workspace-mobile-tab-canvas[aria-selected='true']")
    refute has_element?(view, "#workspace-mobile-tab-utility")
    refute has_element?(view, "#workspace-mobile-tab-ephemeral")

    html =
      view
      |> element("#workspace-launcher-toggle")
      |> render_click()

    assert html =~ ~s(data-launcher-open="true")
    assert has_element?(view, "#workspace-launcher-toggle[aria-expanded='true']")

    html =
      view
      |> element("#workspace-dest-output")
      |> render_click()

    assert html =~ ~s(data-launcher-open="false")
    assert has_element?(view, "#workspace-shell[data-mobile-tab='canvas']")
    assert has_element?(view, "#workspace-shell[data-canvas-drawer='open']")
  end

  test "AppBar destination links open workspace Canvas destinations", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    view
    |> element("#workspace-objective-count-chip")
    |> render_click()

    assert_patch(
      view,
      ~p"/workspace?#{[thread_id: thread_id, destination: "workspace:objectives"]}"
    )

    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:objectives']")
    assert has_element?(view, "#workspace-shell[data-canvas-drawer='open']")
    assert has_element?(view, "#workspace-canvas[data-destination='workspace:objectives']")

    view
    |> element("#workspace-overflow-menu")
    |> render_click()

    assert has_element?(view, "#workspace-overflow-settings-link")

    view
    |> element("#workspace-overflow-settings-link")
    |> render_click()

    assert_patch(
      view,
      ~p"/workspace?#{[thread_id: thread_id, destination: "workspace:settings"]}"
    )

    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:settings']")
    refute has_element?(view, "#workspace-overflow-menu-items")

    view
    |> element("#workspace-overflow-menu")
    |> render_click()

    assert has_element?(view, "#workspace-overflow-objectives-link")

    view
    |> element("#workspace-overflow-objectives-link")
    |> render_click()

    assert_patch(
      view,
      ~p"/workspace?#{[thread_id: thread_id, destination: "workspace:objectives"]}"
    )

    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:objectives']")
  end

  test "layout override sets default Canvas destination and reorders launcher only", %{conn: conn} do
    Paths.ensure_home!()

    File.write!(
      Path.join([Paths.home(), "workspace", "layout.yaml"]),
      """
      default_destination: workspace:settings
      launcher_order:
        - workspace:settings
        - output
        - workspace:security
      hidden_destinations:
        - workspace:jobs
        - output
        - workspace:settings
      """
    )

    assert {:ok, _setting} =
             Settings.put("workspace.layout.override_enabled", true, %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/workspace")

    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:settings']")
    assert has_element?(view, "#workspace-canvas[data-destination='workspace:settings']")
    assert has_element?(view, "#workspace-dest-workspace-settings")
    assert has_element?(view, "#workspace-dest-output")
    refute has_element?(view, "#workspace-dest-workspace-jobs")

    # v0.61b M7: appbar retired; the theme toggle lives in the sidebar footer
    # and the context indicator in the chat header.
    refute has_element?(view, "#allbert-appbar")
    assert has_element?(view, "#workspace-theme-toggle")
    assert has_element?(view, "#workspace-context-indicator")

    html = render(view)

    assert html_position(html, ~s(id="workspace-dest-workspace-settings")) <
             html_position(html, ~s(id="workspace-dest-output"))

    assert html_position(html, ~s(id="workspace-dest-output")) <
             html_position(html, ~s(id="workspace-dest-workspace-security"))
  end

  # v0.61b M7 (relocation rows 3/15): the appbar thread switcher is retired —
  # the sidebar Conversations section lists and switches threads; "Copy
  # conversation id" survives in the sidebar-footer overflow menu.
  test "sidebar conversations list, overflow copy-id, switching, and creation", %{conn: conn} do
    current_thread = create_workspace_thread("Current workspace thread")
    other_thread = create_workspace_thread("Other workspace thread")

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{current_thread.id}")

    refute has_element?(view, "#workspace-thread-switcher-toggle")

    sections_html = render(element(view, "#sidebar-workspace-sections"))
    assert sections_html =~ "Current workspace thread"
    assert sections_html =~ "Other workspace thread"

    menu_html =
      view
      |> element("#workspace-overflow-menu")
      |> render_click()

    assert menu_html =~ "Copy conversation id"
    refute menu_html =~ "Copy thread id"
    assert has_element?(view, "#workspace-thread-copy-id[data-copy-value='#{current_thread.id}']")

    view
    |> element("#workspace-rail-thread-#{other_thread.id}")
    |> render_click()

    assert_redirect(view, ~p"/workspace?thread_id=#{other_thread.id}")

    {:ok, new_view, _html} = live(conn, ~p"/workspace?thread_id=#{current_thread.id}")

    new_view
    |> element("#sidebar-workspace-sections #workspace-launcher")
    |> render_click()

    {redirected_to, _flash} = assert_redirect(new_view)
    assert redirected_to =~ "/workspace?thread_id="
    [_, new_thread_id] = Regex.run(~r/thread_id=([^&]+)/, redirected_to)
    assert new_thread_id != current_thread.id
    assert {:ok, thread} = Conversations.get_thread("local", new_thread_id)
    assert thread.id == new_thread_id
  end

  test "mount configures workspace offline service worker", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    assert has_element?(
             view,
             "#workspace-shell[data-offline-enabled='true'][data-service-worker-url='/workspace-sw.js'][data-service-worker-scope='/workspace'][data-offline-shell-url='/workspace-offline.html']"
           )

    assert has_element?(
             view,
             "#workspace-offline-banner[hidden][data-state='online'][data-workspace-pattern='status-callout']"
           )
  end

  test "offline disabled setting shows disabled workspace banner", %{conn: conn} do
    assert {:ok, _setting} =
             Settings.put("workspace.offline.enabled", false, %{audit?: false})

    {:ok, view, html} = live(conn, ~p"/workspace")

    assert has_element?(view, "#workspace-shell[data-offline-enabled='false']")

    assert has_element?(
             view,
             "#workspace-offline-banner[data-state='disabled'][data-workspace-pattern='status-callout']"
           )

    refute has_element?(view, "#workspace-offline-banner[hidden]")
    assert html =~ "Offline mode disabled."
  end

  test "mount applies high contrast workspace variant", %{conn: conn} do
    assert {:ok, _setting} = Settings.put("workspace.theme.mode", "dark", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("workspace.accessibility.high_contrast", true, %{audit?: false})

    {:ok, view, html} = live(conn, ~p"/workspace")

    assert html =~ "workspace-high-contrast"
    assert html =~ ~s(data-high-contrast="true")

    assert has_element?(
             view,
             "#workspace-shell.workspace-high-contrast[data-theme='dark'][data-high-contrast='true']"
           )

    assert has_element?(view, "#workspace-theme-toggle[data-high-contrast='true']")
  end

  test "mount applies reduce-motion workspace variant", %{conn: conn} do
    assert {:ok, _setting} =
             Settings.put("workspace.accessibility.reduce_motion", true, %{audit?: false})

    {:ok, view, html} = live(conn, ~p"/workspace")

    assert html =~ "workspace-reduce-motion"
    assert html =~ ~s(data-reduce-motion="true")

    assert has_element?(
             view,
             "#workspace-shell.workspace-reduce-motion[data-reduce-motion='true']"
           )
  end

  test "renders active objective badge from registered action boundary", %{conn: conn} do
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "local",
               title: "Analyze AAPL",
               objective: "Complete one analysis for AAPL.",
               status: "blocked",
               active_app: "stocksage"
             })

    {:ok, view, _html} = live(conn, ~p"/workspace")

    assert has_element?(view, "#objective-badge-#{objective.id}")
  end

  defp html_position(html, marker) do
    case :binary.match(html, marker) do
      {position, _length} -> position
      :nomatch -> flunk("expected rendered HTML to contain #{inspect(marker)}")
    end
  end
end
