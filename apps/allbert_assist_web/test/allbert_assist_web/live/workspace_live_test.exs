defmodule AllbertAssistWeb.WorkspaceLiveTest do
  use AllbertAssistWeb.ConnCase, async: false, lane: :external_runtime_serial

  import Phoenix.LiveViewTest

  alias AllbertAssist.{
    Confirmations,
    Conversations,
    Objectives,
    Paths,
    Runtime,
    Session,
    Settings,
    Workspace
  }

  alias AllbertAssist.Intent.Handoff
  alias AllbertAssist.McpRegistryFixtures
  alias AllbertAssist.Resources.{Grants, ResourceURI, Scope}
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Tools.Discovery
  alias AllbertAssist.Tools.ToolCandidate
  alias AllbertAssist.Workspace.Emitters, as: WorkspaceEmitters
  alias AllbertAssist.Workspace.Fragment.Body, as: FragmentBody
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias AllbertAssist.Workspace.Fragment.SigningSecret
  alias AllbertAssistWeb.SignalBridge
  alias Jido.Signal.Bus

  @runtime_async_timeout 10_000

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-agent-live-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    parent = self()

    runner = fn _signal, request ->
      send(parent, {:runtime_request, request})

      {:ok,
       %{message: "Runtime LiveView response: #{request.text}", status: :completed, actions: []}}
    end

    Application.put_env(:allbert_assist, Runtime, agent_runner: runner)
    _ = Session.clear_active_app("local", "web-local")

    on_exit(fn ->
      _ = Session.clear_active_app("local", "web-local")
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)
  end

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

    assert has_element?(view, "#workspace-renderer")
    assert has_element?(view, "#allbert-appbar")
    assert has_element?(view, "#workspace-node-workspace-nav-rail")
    assert has_element?(view, "#workspace-launcher")
    assert has_element?(view, "#workspace-component-workspace-thread-list")
    assert has_element?(view, "#workspace-component-workspace-app-launcher")
    refute has_element?(view, "#workspace-node-workspace-utility-drawer")
    refute has_element?(view, "#workspace-node-workspace-objectives")

    assert has_element?(
             view,
             "#workspace-context-indicator[data-active-app='allbert']",
             "Neutral"
           )

    refute has_element?(view, "#workspace-context-exit")
    assert has_element?(view, "#workspace-thread-switcher-toggle")
    assert has_element?(view, "#workspace-chat-region")
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
  end

  test "discovery suggestions panel routes connect affordance to confirmation gate", %{conn: conn} do
    {:ok, candidate} =
      persist_discovery_suggestion(McpRegistryFixtures.official_secret_stdio_server())

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:discover")

    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:discover']")
    assert has_element?(view, "[data-workspace-component='settings_card']", candidate.name)
    assert has_element?(view, "button[data-workspace-component='action_button']", "Connect")

    view
    |> element("button[data-workspace-component='action_button']", "Connect")
    |> render_click()

    assert has_element?(view, "#approval-handoff")
    assert [confirmation] = Confirmations.list(status: "pending")
    assert get_in(confirmation, ["target_action", "name"]) == "mcp_server_connect"
    assert get_in(confirmation, ["params_summary", "candidate_id"]) == candidate.id
  end

  test "calendar panel create-event affordance routes through Approval Handoff", %{conn: conn} do
    configure_mcp_server("calendar", ["create_event"])

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:calendar")

    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:calendar']")
    assert has_element?(view, "#workspace-dest-workspace-calendar")
    assert has_element?(view, "[data-workspace-component='settings_card']", "Server calendar")
    assert has_element?(view, "button[data-workspace-component='action_button']", "Create Event")

    view
    |> element("button[data-workspace-component='action_button']", "Create Event")
    |> render_click()

    assert has_element?(view, "#approval-handoff")
    assert [confirmation] = Confirmations.list(status: "pending")
    assert get_in(confirmation, ["target_action", "name"]) == "mcp_call_tool"
    assert get_in(confirmation, ["params_summary", "server_id"]) == "calendar"
    assert get_in(confirmation, ["params_summary", "tool_name"]) == "create_event"
  end

  test "mail panel reply affordance routes through Approval Handoff", %{conn: conn} do
    configure_mcp_server("mail", ["reply_message"])

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:mail")

    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:mail']")
    assert has_element?(view, "#workspace-dest-workspace-mail")
    assert has_element?(view, "[data-workspace-component='settings_card']", "Server mail")
    assert has_element?(view, "button[data-workspace-component='action_button']", "Reply")

    view
    |> element("button[data-workspace-component='action_button']", "Reply")
    |> render_click()

    assert has_element?(view, "#approval-handoff")
    assert [confirmation] = Confirmations.list(status: "pending")
    assert get_in(confirmation, ["target_action", "name"]) == "mcp_call_tool"
    assert get_in(confirmation, ["params_summary", "server_id"]) == "mail"
    assert get_in(confirmation, ["params_summary", "tool_name"]) == "reply_message"
  end

  test "github panel comment affordance routes through Approval Handoff", %{conn: conn} do
    configure_mcp_server("github", ["create_issue_comment"])

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:github")

    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:github']")
    assert has_element?(view, "#workspace-dest-workspace-github")
    assert has_element?(view, "[data-workspace-component='settings_card']", "Server github")
    assert has_element?(view, "button[data-workspace-component='action_button']", "Comment")

    view
    |> element("button[data-workspace-component='action_button']", "Comment")
    |> render_click()

    assert has_element?(view, "#approval-handoff")
    assert [confirmation] = Confirmations.list(status: "pending")
    assert get_in(confirmation, ["target_action", "name"]) == "mcp_call_tool"
    assert get_in(confirmation, ["params_summary", "server_id"]) == "github"
    assert get_in(confirmation, ["params_summary", "tool_name"]) == "create_issue_comment"
  end

  test "mount binds workspace to a real conversation thread", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    assert String.starts_with?(thread_id, "thr_")
    assert {:ok, thread} = Conversations.get_thread("local", thread_id)
    assert thread.id == thread_id
  end

  test "mount treats nil thread query params as absent", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/workspace?thread_id=nil")
    thread_id = workspace_thread_id(view)

    assert String.starts_with?(thread_id, "thr_")
    assert {:ok, thread} = Conversations.get_thread("local", thread_id)
    assert thread.id == thread_id
    refute html =~ "Workspace thread fallback"
    refute html =~ ~s({:thread_not_found, "nil"})
  end

  test "chat pane renders persisted thread messages when available", %{conn: conn} do
    assert {:ok, thread} = Conversations.create_general_thread("local", "Analyze AAPL")

    assert {:ok, _message} =
             Conversations.append_user_message(thread, "analyze AAPL", %{channel: :live_view})

    assert {:ok, _message} =
             Conversations.append_assistant_message(thread, "Started the AAPL analysis.", %{
               channel: :live_view
             })

    {:ok, view, html} = live(conn, ~p"/workspace?thread_id=#{thread.id}&app_id=stocksage")

    assert workspace_thread_id(view) == thread.id
    assert html =~ "analyze AAPL"
    assert html =~ "Started the AAPL analysis."
    assert html =~ "Allbert"
    refute html =~ "Prompt draft"
  end

  test "mount treats empty and null thread query params as absent", %{conn: conn} do
    for query <- ["thread_id=", "thread_id=null"] do
      {:ok, view, html} = live(conn, "/workspace?#{query}")
      thread_id = workspace_thread_id(view)

      assert String.starts_with?(thread_id, "thr_")
      assert {:ok, thread} = Conversations.get_thread("local", thread_id)
      assert thread.id == thread_id
      refute html =~ "Workspace thread fallback"
      refute html =~ "workspace-thread-notice"
    end
  end

  test "mount recovers stale explicit thread query params quietly", %{conn: conn} do
    assert {:ok, recent_thread} =
             Conversations.create_general_thread("local", "Existing workspace thread")

    assert {:ok, _message} =
             Conversations.append_user_message(recent_thread, "do not reuse this thread", %{
               channel: :live_view
             })

    {:ok, view, html} = live(conn, ~p"/workspace?thread_id=thr_missing_manual")
    thread_id = workspace_thread_id(view)

    assert String.starts_with?(thread_id, "thr_")
    assert thread_id != "thr_missing_manual"
    assert thread_id != recent_thread.id
    assert {:ok, thread} = Conversations.get_thread("local", thread_id)
    assert thread.id == thread_id
    assert has_element?(view, "#workspace-thread-notice[role='status']")
    assert html =~ "Started a new workspace thread"
    assert html =~ "thr_missing_manual"
    refute html =~ "do not reuse this thread"
    assert_patch(view, ~p"/workspace?thread_id=#{thread_id}")
    refute has_element?(view, "#agent-error")
    refute html =~ "Workspace thread fallback"
    refute html =~ ~s({:thread_not_found, "thr_missing_manual"})
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

  test "workspace settings destination renders Settings Central and updates through actions",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    html =
      view
      |> element("#workspace-dest-workspace-settings")
      |> render_click()

    assert html =~ "Settings Central"
    assert has_element?(view, "#workspace-settings-panel")
    refute has_element?(view, "[data-workspace-component='job_card']")
    refute has_element?(view, "[data-workspace-component='confirmation_card']")
    assert has_element?(view, "#settings-list")
    assert has_element?(view, "#settings-form")
    assert has_element?(view, "#workspace-theme-diagnostics")
    assert has_element?(view, "#workspace-theme-token-status")
    assert has_element?(view, "#workspace-theme-snippet-status")
    assert has_element?(view, "#workspace-layout-status")
    assert has_element?(view, "#security-status")
    assert has_element?(view, "#confirmation-requests")
    assert has_element?(view, "#remembered-resource-grants")
    assert has_element?(view, "#provider-key-form")
    assert has_element?(view, "#doctor-model-local")
    assert has_element?(view, "#use-model-local")

    subscribe_actions()

    html =
      view
      |> element("#settings-form")
      |> render_submit(%{
        "setting" => %{
          "key" => "operator.communication_style",
          "value" => "concise"
        }
      })

    assert html =~ "Setting saved."
    assert html =~ "settings-audit"
    assert {:ok, "concise"} = Settings.get("operator.communication_style")

    action_signal = receive_action_completed("update_setting")
    assert action_signal.data.status == :completed
    assert action_signal.data.permission_decision.permission == :settings_write

    html =
      view
      |> element("#use-model-local")
      |> render_click()

    assert html =~ "Model profile saved."
    assert {:ok, "local"} = Settings.get("intent.model_profile")

    model_signal = receive_action_completed("set_active_model_profile")
    assert model_signal.data.status == :completed
    assert model_signal.data.permission_decision.permission == :settings_write
  end

  test "workspace onboarding destination frames and records onboarding steps", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:onboard")

    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:onboard']")
    assert has_element?(view, "#workspace-canvas[data-destination='workspace:onboard']")
    assert has_element?(view, "#workspace-onboarding-panel")
    assert has_element?(view, "#onboarding-step-welcome_scope[data-current='true']")
    assert has_element?(view, "#complete-onboarding-step-welcome_scope")

    subscribe_actions()

    html =
      view
      |> element("#complete-onboarding-step-welcome_scope")
      |> render_click()

    assert html =~ "Onboarding progress recorded."
    assert has_element?(view, "#onboarding-step-welcome_scope[data-status='completed']")
    assert has_element?(view, "#onboarding-step-pick_provider_profile[data-current='true']")

    action_signal = receive_action_completed("onboarding_step_complete")
    assert action_signal.data.status == :completed
    assert action_signal.data.permission_decision.permission == :objective_write
  end

  test "workspace create gallery only exposes Settings Central allowed patterns", %{conn: conn} do
    assert {:ok, _setting} =
             Settings.put("templates.create.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("templates.allowed_patterns", ["llm_tool"], %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/workspace?#{[destination: "workspace:create"]}")

    assert has_element?(view, "#workspace-create-pattern-llm_tool")
    refute has_element?(view, "#workspace-create-pattern-plugin")
    refute has_element?(view, "#workspace-create-pattern-app")
    assert has_element?(view, "#workspace-create-param-permission")
    assert has_element?(view, "#workspace-create-mode-live:not([disabled])")
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

    assert has_element?(view, "#allbert-appbar")
    assert has_element?(view, "#workspace-theme-toggle")
    assert has_element?(view, "#workspace-context-indicator")

    html = render(view)

    assert html_position(html, ~s(id="workspace-dest-workspace-settings")) <
             html_position(html, ~s(id="workspace-dest-output"))

    assert html_position(html, ~s(id="workspace-dest-output")) <
             html_position(html, ~s(id="workspace-dest-workspace-security"))
  end

  test "workspace Settings Central stores provider keys without exposing the secret", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element("#workspace-dest-workspace-settings")
    |> render_click()

    subscribe_actions()

    html =
      view
      |> element("#provider-key-form")
      |> render_submit(%{
        "provider" => %{
          "provider" => "openai",
          "api_key" => "sk-workspace-secret"
        }
      })

    assert html =~ "Provider credential saved."
    refute html =~ "sk-workspace-secret"

    action_signal = receive_action_completed("set_provider_credential")
    assert action_signal.data.status == :completed
    assert action_signal.data.permission_decision.permission == :settings_secret_write
  end

  test "workspace create destination is denied when disabled", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/workspace?destination=workspace:create")

    assert has_element?(view, "#workspace-dest-create")
    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:create']")
    assert has_element?(view, "#workspace-canvas[data-destination='workspace:create']")
    assert has_element?(view, "#workspace-create-panel[data-enabled='false']")
    assert has_element?(view, "#workspace-create-gallery")
    assert has_element?(view, "#workspace-create-params")
    assert has_element?(view, "#workspace-create-preview")
    assert has_element?(view, "#workspace-create-validate[data-validation-status='denied']")
    assert html =~ "Template creation is disabled by Settings Central."
  end

  test "workspace create renders gallery, params, preview, and validation", %{conn: conn} do
    assert {:ok, _setting} = Settings.put("templates.create.enabled", true, %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:create")

    assert has_element?(view, "#workspace-create-panel[data-enabled='true']")
    assert has_element?(view, "#workspace-create-gallery")
    assert has_element?(view, "#workspace-create-params")
    assert has_element?(view, "#workspace-create-preview")
    assert has_element?(view, "#workspace-create-validate[data-validation-status='ready']")

    assert has_element?(
             view,
             "#workspace-create-pattern-llm_tool.workspace-create-pattern-active"
           )

    assert has_element?(view, "#workspace-create-mode-live:not([disabled])")

    html =
      view
      |> element("#workspace-create-params")
      |> render_change(%{
        "template" => %{
          "pattern_id" => "llm_tool",
          "mode" => "developer_scaffold",
          "name" => "custom_weather_tool",
          "description" => "Reviewed weather lookup.",
          "instruction" => "Return a concise response.",
          "permission" => "read_only",
          "version" => "0.1.0"
        }
      })

    assert html =~ "dynamic_manifest.json"
    assert html =~ "source/lib/action.ex"
    assert has_element?(view, "#workspace-create-validate[data-validation-status='ready']")
  end

  test "workspace create disables unsupported live mode", %{
    conn: conn
  } do
    assert {:ok, _setting} = Settings.put("templates.create.enabled", true, %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:create")

    view
    |> element("#workspace-create-pattern-plugin")
    |> render_click()

    assert has_element?(view, "#workspace-create-mode-live[disabled]")
  end

  test "workspace create live submit fails closed when dynamic codegen is disabled", %{
    conn: conn
  } do
    assert {:ok, _setting} = Settings.put("templates.create.enabled", true, %{audit?: false})

    slug = "new_llm_tool"
    scaffold_target = Path.join(File.cwd!(), "plugins/#{slug}")
    draft_target = Path.join([Paths.home(), "dynamic_plugins", "drafts", slug])

    refute File.exists?(scaffold_target)
    refute File.exists?(draft_target)

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:create")
    subscribe_actions()

    mode_html =
      view
      |> element("#workspace-create-mode-live")
      |> render_click()

    assert mode_html =~ ~s(data-output-mode="live_integration")
    assert has_element?(view, "#workspace-create-run:not([disabled])")

    html =
      view
      |> element("#workspace-create-run")
      |> render_click()

    assert html =~ "Template live draft was denied or unavailable"
    assert html =~ "dynamic_codegen_disabled"

    refute File.exists?(scaffold_target)
    refute File.exists?(draft_target)

    action_signal = receive_action_completed("create_from_template")
    assert action_signal.data.status == :denied
  end

  test "workspace create live submit fails closed when live loader is disabled", %{
    conn: conn
  } do
    assert {:ok, _setting} = Settings.put("templates.create.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("dynamic_codegen.enabled", true, %{audit?: false})

    slug = "new_llm_tool"
    draft_target = Path.join([Paths.home(), "dynamic_plugins", "drafts", slug])

    refute File.exists?(draft_target)

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:create")
    subscribe_actions()

    view
    |> element("#workspace-create-mode-live")
    |> render_click()

    html =
      view
      |> element("#workspace-create-run")
      |> render_click()

    assert html =~ "Template live draft was denied or unavailable"
    assert html =~ "dynamic_live_loader_disabled"

    refute File.exists?(draft_target)

    action_signal = receive_action_completed("create_from_template")
    assert action_signal.data.status == :denied
  end

  test "workspace create live submit writes only a templated dynamic draft", %{
    conn: conn
  } do
    assert {:ok, _setting} = Settings.put("templates.create.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("dynamic_codegen.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("dynamic_codegen.live_loader_enabled", true, %{audit?: false})

    assert {:ok, _setting} = Settings.put("sandbox.elixir.enabled", true, %{audit?: false})

    slug = "new_llm_tool"
    scaffold_target = Path.join(File.cwd!(), "plugins/#{slug}")
    draft_target = Path.join([Paths.home(), "dynamic_plugins", "drafts", slug])

    refute File.exists?(scaffold_target)
    refute File.exists?(draft_target)

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:create")
    subscribe_actions()

    view
    |> element("#workspace-create-mode-live")
    |> render_click()

    html =
      view
      |> element("#workspace-create-run")
      |> render_click()

    assert html =~ "Templated dynamic draft #{slug} created."
    refute File.exists?(scaffold_target)
    assert File.regular?(Path.join(draft_target, "metadata.yaml"))

    assert File.read!(Path.join(draft_target, "metadata.yaml")) =~
             "template_pattern_id: llm_tool"

    action_signal = receive_action_completed("create_from_template")
    assert action_signal.data.status == :completed
  end

  test "workspace Settings Central approves, denies, and revokes through registered actions",
       %{conn: conn} do
    assert {:ok, approve_candidate} =
             Confirmations.create(confirmation_attrs("conf_workspace_settings_approve"))

    assert {:ok, deny_candidate} =
             Confirmations.create(confirmation_attrs("conf_workspace_settings_deny"))

    assert {:ok, grant} =
             Grants.remember(external_ref("https://example.com/settings-central"),
               id: "grant_workspace_settings",
               reason: "workspace settings test",
               audit?: false
             )

    {:ok, view, _html} = live(conn, ~p"/workspace")

    html =
      view
      |> element("#workspace-dest-workspace-settings")
      |> render_click()

    assert html =~ approve_candidate["id"]
    assert html =~ deny_candidate["id"]
    assert html =~ grant["id"]

    subscribe_actions()

    view
    |> element("#approve-confirmation-#{approve_candidate["id"]}")
    |> render_click()

    approve_signal = receive_action_completed("approve_confirmation")
    assert approve_signal.data.status == :completed
    assert {:ok, approved} = Confirmations.read(approve_candidate["id"])
    refute approved["status"] == "pending"

    view
    |> element("#deny-confirmation-#{deny_candidate["id"]}-form")
    |> render_submit(%{
      "confirmation" => %{"id" => deny_candidate["id"], "reason" => "not needed"}
    })

    deny_signal = receive_action_completed("deny_confirmation")
    assert deny_signal.data.status == :completed
    assert {:ok, denied} = Confirmations.read(deny_candidate["id"])
    assert denied["status"] == "denied"

    view
    |> element("#revoke-resource-grant-#{grant["id"]}")
    |> render_click()

    revoke_signal = receive_action_completed("revoke_resource_grant")
    assert revoke_signal.data.status == :completed

    assert {:error, {:grant_revoked, "grant_workspace_settings"}} =
             Grants.find_applicable(external_ref("https://example.com/settings-central"),
               permission: :external_network
             )
  end

  test "thread switcher lists, copies, switches, and creates threads", %{conn: conn} do
    current_thread = create_workspace_thread("Current workspace thread")
    other_thread = create_workspace_thread("Other workspace thread")

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{current_thread.id}")

    menu_html =
      view
      |> element("#workspace-thread-switcher-toggle")
      |> render_click()

    assert menu_html =~ "Current workspace thread"
    assert menu_html =~ "Other workspace thread"

    assert has_element?(
             view,
             "#workspace-thread-switcher-toggle[aria-haspopup='menu'][aria-expanded='true']"
           )

    assert has_element?(view, "#workspace-thread-switcher-menu[role='menu']")
    assert has_element?(view, "#workspace-thread-item-#{other_thread.id}")
    assert has_element?(view, "#workspace-thread-new[phx-click='new_thread']")
    assert has_element?(view, "#workspace-thread-copy-id[data-copy-value='#{current_thread.id}']")

    view
    |> element("#workspace-thread-item-#{other_thread.id}")
    |> render_click()

    assert_redirect(view, ~p"/workspace?thread_id=#{other_thread.id}")

    {:ok, new_view, _html} = live(conn, ~p"/workspace?thread_id=#{current_thread.id}")

    new_view
    |> element("#workspace-thread-switcher-toggle")
    |> render_click()

    new_view
    |> element("#workspace-thread-new")
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

    assert has_element?(view, "#workspace-offline-banner[hidden][data-state='online']")
  end

  test "offline disabled setting shows disabled workspace banner", %{conn: conn} do
    assert {:ok, _setting} =
             Settings.put("workspace.offline.enabled", false, %{audit?: false})

    {:ok, view, html} = live(conn, ~p"/workspace")

    assert has_element?(view, "#workspace-shell[data-offline-enabled='false']")
    assert has_element?(view, "#workspace-offline-banner[data-state='disabled']")
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

  test "renders emitted canvas fragments through the workspace shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    envelope =
      signed_envelope(%{
        thread_id: thread_id,
        surface: fragment_surface(:text, "Canvas fragment body")
      })

    assert :ok = Workspace.emit_fragment(envelope)

    html = render_until(view, "Canvas fragment body")

    assert has_element?(view, "#workspace-node-canvas-tile-#{envelope.id}")
    assert html =~ "Canvas fragment body"

    assert {:ok, [tile]} = Workspace.canvas_tiles(thread_id, "local")
    assert tile.id == envelope.id
  end

  test "renders emitted ephemeral fragments through the workspace shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    envelope =
      signed_envelope(%{
        thread_id: thread_id,
        scope: :ephemeral,
        kind: :approval_card,
        surface: fragment_surface(:approval_card, "Approval fragment body")
      })

    assert :ok = Workspace.emit_fragment(envelope)

    html = render_until(view, "Approval fragment body")

    assert has_element?(view, "#workspace-node-ephemeral-surface-#{envelope.id}")
    assert html =~ "Approval fragment body"

    assert {:ok, [surface]} = Workspace.ephemeral_surfaces(thread_id, "local")
    assert surface.id == envelope.id
  end

  test "workspace ephemeral dismissal routes Escape through the action boundary", %{conn: conn} do
    thread = create_workspace_thread()

    envelope =
      signed_envelope(%{
        thread_id: thread.id,
        scope: :ephemeral,
        kind: :approval_card,
        surface: fragment_surface(:approval_card, "Dismiss me")
      })

    assert :ok = Workspace.emit_fragment(envelope)

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")
    assert has_element?(view, "#workspace-node-ephemeral-surface-#{envelope.id}")

    assert has_element?(
             view,
             "#workspace-node-ephemeral-surface-#{envelope.id}[phx-key='escape']"
           )

    subscribe_actions()

    view
    |> element("#workspace-node-ephemeral-surface-#{envelope.id}")
    |> render_keydown(%{"key" => "Escape"})

    action_signal = receive_action_completed("dismiss_workspace_ephemeral")
    assert action_signal.data.status == :completed
    assert action_signal.data.permission_decision.permission == :workspace_canvas_write
    assert {:ok, []} = Workspace.ephemeral_surfaces(thread.id, "local")
  end

  test "intent handoff accept sets active app and resubmits the prompt", %{conn: conn} do
    thread = create_workspace_thread()

    handoff =
      Handoff.new!(%{
        kind: :app_handoff,
        app_id: :stocksage,
        action_name: "run_analysis",
        label: "Run StockSage analysis",
        source_text: "analyze CIEN",
        extracted_slots: %{ticker: "CIEN"}
      })

    assert :ok =
             WorkspaceEmitters.intent_proposal(handoff, %{
               user_id: "local",
               thread_id: thread.id
             })

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")
    html = render_until(view, "Open StockSage?")

    assert has_element?(view, "#intent-handoff")
    assert has_element?(view, "#intent-handoff-accept")
    assert has_element?(view, "#intent-handoff-decline")
    assert html =~ "Accept the handoff"

    subscribe_actions()

    view
    |> element("#intent-handoff-accept")
    |> render_click()

    assert_receive {:runtime_request, %{text: "analyze CIEN", active_app: :stocksage}},
                   @runtime_async_timeout

    assert receive_action_completed("set_active_app").data.status == :completed

    html = render_until(view, "Runtime LiveView response: analyze CIEN")
    assert html =~ ~s(data-active-app="stocksage")
    assert has_element?(view, "#workspace-context-indicator[data-active-app='stocksage']")
    assert has_element?(view, "#workspace-context-exit")
    assert {:ok, []} = Workspace.ephemeral_surfaces(thread.id, "local")
  end

  test "intent handoff accept can open a workspace destination without resubmitting", %{
    conn: conn
  } do
    thread = create_workspace_thread()

    handoff =
      Handoff.new!(%{
        kind: :app_handoff,
        app_id: :allbert,
        action_name: "open_calendar_panel",
        label: "Open Calendar agenda",
        source_text: "show me today's agenda",
        destination: "workspace:calendar"
      })

    assert :ok =
             WorkspaceEmitters.intent_proposal(handoff, %{
               user_id: "local",
               thread_id: thread.id
             })

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")
    assert render_until(view, "Open Calendar?") =~ "Accept the handoff"

    view
    |> element("#intent-handoff-accept")
    |> render_click()

    assert_patch(
      view,
      ~p"/workspace?#{[thread_id: thread.id, destination: "workspace:calendar"]}"
    )

    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:calendar']")
    assert {:ok, []} = Workspace.ephemeral_surfaces(thread.id, "local")
    refute_receive {:runtime_request, _request}, 100
  end

  test "intent handoff decline dismisses without setting active app", %{conn: conn} do
    thread = create_workspace_thread()

    handoff =
      Handoff.new!(%{
        kind: :app_handoff,
        app_id: :stocksage,
        action_name: "run_analysis",
        label: "Run StockSage analysis",
        source_text: "analyze CIEN",
        extracted_slots: %{ticker: "CIEN"}
      })

    assert :ok =
             WorkspaceEmitters.intent_proposal(handoff, %{
               user_id: "local",
               thread_id: thread.id
             })

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")
    assert render_until(view, "Open StockSage?") =~ "Accept the handoff"

    subscribe_actions()

    view
    |> element("#intent-handoff-decline")
    |> render_click()

    action_signal = receive_action_completed("dismiss_workspace_ephemeral")
    assert action_signal.data.status == :completed
    assert {:ok, []} = Workspace.ephemeral_surfaces(thread.id, "local")
    refute_received {:runtime_request, _request}
    assert render(view) =~ ~s(data-active-app="allbert")

    assert has_element?(
             view,
             "#workspace-context-indicator[data-active-app='allbert']",
             "Neutral"
           )
  end

  test "context indicator exit clears active app without changing canvas destination", %{
    conn: conn
  } do
    ensure_stocksage_app_registered()
    assert {:ok, _entry} = Session.set_active_app("local", "web-local", :stocksage)

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=app:stocksage")

    assert has_element?(view, "#workspace-context-indicator[data-active-app='stocksage']")
    assert has_element?(view, "#workspace-context-exit")
    assert has_element?(view, "#workspace-shell[data-canvas-destination='app:stocksage']")

    subscribe_actions()

    html =
      view
      |> element("#workspace-context-exit")
      |> render_click()

    assert html =~ ~s(data-active-app="allbert")

    assert has_element?(
             view,
             "#workspace-context-indicator[data-active-app='allbert']",
             "Neutral"
           )

    refute has_element?(view, "#workspace-context-exit")
    assert has_element?(view, "#workspace-shell[data-canvas-destination='app:stocksage']")

    action_signal = receive_action_completed("clear_active_app")
    assert action_signal.data.status == :completed
    assert {:ok, %{active_app: nil}} = Session.get("local", "web-local")
  end

  test "canvas tile controls route through the workspace action boundary", %{conn: conn} do
    thread = create_workspace_thread()

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: "local",
               thread_id: thread.id,
               kind: :text,
               body: %{text: "operator tile controls"}
             })

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")
    subscribe_actions()

    assert has_element?(view, "#workspace-tile-action-#{tile.id}:not([disabled])")
    assert has_element?(view, "#workspace-tile-menu-button-#{tile.id}:not([disabled])")
    assert has_element?(view, "#workspace-tile-action-#{tile.id}[phx-disable-with]")

    assert has_element?(
             view,
             "#workspace-tile-menu-button-#{tile.id}[aria-haspopup='menu'][aria-expanded='false']"
           )

    view
    |> element("#workspace-tile-action-#{tile.id}")
    |> render_click()

    action_signal = receive_action_completed("manage_workspace_tile")
    assert action_signal.data.status == :completed
    assert action_signal.data.permission_decision.permission == :workspace_canvas_write
    assert {:ok, pinned} = Workspace.get_tile(tile.id, "local")
    assert pinned.pinned == true

    menu_html =
      view
      |> element("#workspace-tile-menu-button-#{tile.id}")
      |> render_click()

    assert menu_html =~ "Remove tile"

    assert has_element?(
             view,
             "#workspace-tile-menu-button-#{tile.id}[aria-haspopup='menu'][aria-expanded='true']"
           )

    view
    |> element("#workspace-tile-menu-#{tile.id} [phx-value-operation='remove']")
    |> render_click()

    remove_signal = receive_action_completed("manage_workspace_tile")
    assert remove_signal.data.status == :completed
    assert [remove_action] = remove_signal.data.response.actions
    assert remove_action.workspace_metadata.operation == :remove
    assert {:ok, []} = Workspace.canvas_tiles(thread.id, "local")
    assert {:ok, [deleted]} = Workspace.canvas_tiles(thread.id, "local", include_deleted: true)
    refute is_nil(deleted.deleted_at)
  end

  test "tile inspector opens from the tile menu and closes by Escape or button", %{conn: conn} do
    thread = create_workspace_thread()

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: "local",
               thread_id: thread.id,
               kind: :text,
               body: %{text: "operator tile inspector body"},
               metadata: %{"emitter_id" => "AllbertAssist.TestEmitter"}
             })

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    menu_html =
      view
      |> element("#workspace-tile-menu-button-#{tile.id}")
      |> render_click()

    assert menu_html =~ "Inspect"

    assert has_element?(
             view,
             "#workspace-tile-inspect-#{tile.id}[phx-click='open_tile_inspector']"
           )

    inspector_html =
      view
      |> element("#workspace-tile-inspect-#{tile.id}")
      |> render_click()

    assert inspector_html =~ "Tile inspector"
    assert inspector_html =~ "operator tile inspector body"
    assert inspector_html =~ "AllbertAssist.TestEmitter"
    assert has_element?(view, "#workspace-tile-inspector[role='dialog'][phx-hook='FocusTrap']")
    assert has_element?(view, "#workspace-tile-inspector-copy-id[data-copy-value='#{tile.id}']")
    assert has_element?(view, "#workspace-tile-inspector-copy-body")
    refute has_element?(view, "#workspace-tile-menu-#{tile.id}")

    view
    |> element("#workspace-tile-inspector")
    |> render_keydown(%{"key" => "Escape"})

    refute has_element?(view, "#workspace-tile-inspector")

    view
    |> element("#workspace-tile-menu-button-#{tile.id}")
    |> render_click()

    view
    |> element("#workspace-tile-inspect-#{tile.id}")
    |> render_click()

    view
    |> element("#workspace-tile-inspector-close")
    |> render_click()

    refute has_element?(view, "#workspace-tile-inspector")
  end

  test "ephemeral lifecycle events fan out open and close to sibling tabs", %{conn: conn} do
    start_workspace_bridge()
    thread = create_workspace_thread()

    {:ok, first_tab, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")
    {:ok, second_tab, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    envelope =
      signed_envelope(%{
        thread_id: thread.id,
        scope: :ephemeral,
        kind: :approval_card,
        surface: fragment_surface(:approval_card, "Synced approval")
      })

    assert {:ok, surface} =
             Workspace.open_ephemeral(%{
               id: envelope.id,
               user_id: "local",
               thread_id: thread.id,
               kind: :approval_card,
               body: FragmentBody.encode(envelope)
             })

    render_until(first_tab, "ephemeral-surface-#{surface.id}")
    render_until(second_tab, "ephemeral-surface-#{surface.id}")
    subscribe_actions()

    render_hook(first_tab, :dismiss_workspace_ephemeral, %{"surface-id" => surface.id})

    action_signal = receive_action_completed("dismiss_workspace_ephemeral")
    assert action_signal.data.status == :completed

    render_until_missing(first_tab, "#workspace-node-ephemeral-surface-#{surface.id}")
    render_until_missing(second_tab, "#workspace-node-ephemeral-surface-#{surface.id}")
  end

  test "renders canvas-header badge fragments without persisting them as tiles", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    envelope =
      signed_envelope(%{
        thread_id: thread_id,
        emitter_id: "AllbertAssist.Workspace.Canvas",
        kind: :badge_strip,
        metadata: %{placement: "canvas_header"},
        surface: fragment_surface(:status_badge, "1 older tile(s) archived")
      })

    assert :ok = Workspace.emit_fragment(envelope)

    html = render_until(view, "1 older tile(s) archived")

    assert has_element?(view, "#workspace-header-badge-#{envelope.id}")
    assert html =~ "1 older tile(s) archived"
    assert {:ok, []} = Workspace.canvas_tiles(thread_id, "local")
  end

  test "ignores fragments for a different thread", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    envelope =
      signed_envelope(%{
        thread_id: "thr_other_thread",
        surface: fragment_surface(:text, "Wrong thread body")
      })

    assert :ok = Workspace.emit_fragment(envelope)

    html = render(view)

    refute html =~ "Wrong thread body"
    assert {:ok, []} = Workspace.canvas_tiles(thread_id, "local")
  end

  test "workspace tile mutations fan out to a second tab", %{conn: conn} do
    start_workspace_bridge()

    {:ok, first_tab, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(first_tab)
    {:ok, second_tab, _html} = live(conn, ~p"/workspace?thread_id=#{thread_id}")

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: "local",
               thread_id: thread_id,
               kind: :text,
               body: %{text: "two-tab sync tile"}
             })

    html = render_until(second_tab, tile.id)

    assert html =~ "canvas-tile-#{tile.id}"
  end

  test "workspace tile mutations fan out to three tabs", %{conn: conn} do
    start_workspace_bridge()

    {:ok, first_tab, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(first_tab)

    tabs =
      for _index <- 1..3 do
        assert {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread_id}")
        view
      end

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: "local",
               thread_id: thread_id,
               kind: :text,
               body: %{text: "three-tab sync tile"}
             })

    for view <- tabs do
      html = render_until(view, tile.id)
      assert html =~ "canvas-tile-#{tile.id}"
    end
  end

  test "renders editable text tiles with a Yjs-backed editor hook", %{conn: conn} do
    thread = create_workspace_thread()

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: "local",
               thread_id: thread.id,
               kind: :text,
               body: %{text: "offline draft body"}
             })

    {:ok, view, html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")
    subscribe_actions()

    assert has_element?(
             view,
             "#workspace-tile-editor-#{tile.id}[phx-hook='WorkspaceTileEditor'][phx-update='ignore'][data-tile-id='#{tile.id}'][data-thread-id='#{thread.id}'][data-user-id='local'][data-quota-bytes='33554432']"
           )

    assert html =~ "offline draft body"

    render_hook(view, :workspace_tile_editor_sync, %{
      "tile_id" => tile.id,
      "thread_id" => thread.id,
      "user_id" => "local",
      "kind" => "text",
      "update" => "AQID",
      "state_vector" => "BAUG",
      "snapshot" => "offline draft body"
    })

    tile_id = tile.id
    action_signal = receive_action_completed("record_workspace_offline_update")
    assert action_signal.data.status == :completed
    assert action_signal.data.permission_decision.permission == :workspace_canvas_write

    assert_reply(view, %{
      status: "received",
      tile_id: ^tile_id,
      revision_id: revision_id,
      current_revision_id: revision_id,
      conflict_count: 0,
      max_bytes: 33_554_432
    })
  end

  test "workspace tile editor hook respects workspace write denial", %{conn: conn} do
    thread = create_workspace_thread()

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: "local",
               thread_id: thread.id,
               kind: :text,
               body: %{text: "permission base"}
             })

    assert {:ok, _setting} =
             Settings.put("permissions.workspace_canvas_write", "denied", %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    render_hook(view, :workspace_tile_editor_sync, %{
      "tile_id" => tile.id,
      "thread_id" => thread.id,
      "snapshot" => "blocked edit"
    })

    assert_reply(view, %{status: "rejected", reason: ":permission_denied"})
    assert {:ok, "permission base"} = Workspace.latest_offline_snapshot(tile.id, "local")
  end

  test "workspace tile editor hook reports stale-base conflicts", %{conn: conn} do
    thread = create_workspace_thread()

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: "local",
               thread_id: thread.id,
               kind: :text,
               body: %{text: "conflict base"}
             })

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    render_hook(view, :workspace_tile_editor_sync, %{
      "tile_id" => tile.id,
      "thread_id" => thread.id,
      "user_id" => "local",
      "kind" => "text",
      "snapshot" => "first synced edit"
    })

    tile_id = tile.id

    assert_reply(view, %{
      status: "received",
      tile_id: ^tile_id,
      current_revision_id: first_revision_id,
      conflict_count: 0
    })

    render_hook(view, :workspace_tile_editor_sync, %{
      "tile_id" => tile.id,
      "thread_id" => thread.id,
      "user_id" => "local",
      "kind" => "text",
      "base_revision_id" => nil,
      "origin" => "offline_reconnect",
      "snapshot" => "stale offline edit"
    })

    assert_reply(view, %{
      status: "conflict",
      tile_id: ^tile_id,
      current_revision_id: current_revision_id,
      conflict_count: 1
    })

    assert current_revision_id != first_revision_id

    html = render_until(view, "Conflict reconciled.")
    assert html =~ "1 offline edit(s) were merged"
    assert html =~ "revert_tile_revision"
  end

  test "workspace tile editor hook rejects non-editable tiles", %{conn: conn} do
    thread = create_workspace_thread()

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: "local",
               thread_id: thread.id,
               kind: :analysis_card,
               body: %{text: "read-only analysis"}
             })

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    refute has_element?(view, "#workspace-tile-editor-#{tile.id}")

    render_hook(view, :workspace_tile_editor_sync, %{
      "tile_id" => tile.id,
      "update" => "AQID",
      "state_vector" => "BAUG",
      "snapshot" => "read-only analysis"
    })

    assert_reply(view, %{status: "rejected", reason: ":unsupported_tile_kind"})
  end

  test "renders durable StockSage canvas tiles with real card renderers", %{conn: conn} do
    ensure_stocksage_app_registered()
    thread = create_workspace_thread("StockSage canvas thread")

    envelope =
      signed_envelope(%{
        id: "stocksage_analysis_ana_live_canvas",
        user_id: "local",
        thread_id: thread.id,
        emitter_id: "StockSage.Actions.RunAnalysis",
        scope: :canvas,
        kind: :analysis_card,
        surface: stocksage_analysis_surface("ana_live_canvas")
      })

    assert :ok = Workspace.emit_fragment(envelope)

    {:ok, view, html} = live(conn, ~p"/workspace?thread_id=#{thread.id}&app_id=stocksage")

    assert has_element?(view, ~s([data-stocksage-component="analysis_card"]))
    assert has_element?(view, "#workspace-tile-menu-button-stocksage_analysis_ana_live_canvas")
    assert html =~ "AAPL analysis completed"
    assert html =~ "Constructive setup."
    refute html =~ "v0.26 stub"
    refute html =~ "workspace-card-stub"
  end

  test "submits prompts through the runtime boundary", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Say hello from the runtime boundary."})

    html = render_async(view, @runtime_async_timeout)

    assert_receive {:runtime_request, request}
    assert request.thread_id == thread_id
    assert request.session_id == "web-local"
    assert request.active_app == :allbert

    assert has_element?(view, "#agent-response")
    assert html =~ "Runtime LiveView response: Say hello from the runtime boundary."
    assert has_element?(view, "#agent-status")
    assert html =~ "completed"
    assert has_element?(view, "#agent-signal")
  end

  test "stale app query params do not set runtime active app context", %{conn: conn} do
    fixture = EvalInventory.row!("stale-url-handoff-bypass-001")
    ensure_stocksage_app_registered()

    {:ok, view, _html} =
      live(conn, ~p"/workspace?#{[app_id: "stocksage", active_app: "stocksage"]}")

    thread_id = workspace_thread_id(view)

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "analyze AAPL"})

    _html = render_async(view, @runtime_async_timeout)

    assert_receive {:runtime_request, request}
    assert request.thread_id == thread_id
    assert request.session_id == "web-local"
    assert request.active_app == :allbert

    eval =
      live_security_eval(
        fixture,
        if(request.active_app == :allbert and neutral_session?(Session.get("local", "web-local")),
          do: :denied,
          else: :allowed
        ),
        %{
          boundary: :workspace_url_params,
          stale_params: [:app_id, :active_app],
          active_app: request.active_app
        }
      )

    assert eval.decision == fixture.expected
  end

  test "app launcher selection changes only canvas destination", %{conn: conn} do
    fixture = EvalInventory.row!("launcher-destination-context-001")
    ensure_stocksage_app_registered()

    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    assert has_element?(view, "#workspace-dest-app-stocksage[data-destination='app:stocksage']")

    view
    |> element("#workspace-dest-app-stocksage")
    |> render_click()

    assert_patch(view, ~p"/workspace?#{[thread_id: thread_id, destination: "app:stocksage"]}")
    assert neutral_session?(Session.get("local", "web-local"))
    assert has_element?(view, "#workspace-shell[data-active-app='allbert']")
    assert has_element?(view, "#workspace-shell[data-canvas-destination='app:stocksage']")
    assert has_element?(view, "#workspace-dest-app-stocksage[aria-pressed='true']")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "analyze CIEN"})

    _html = render_async(view, @runtime_async_timeout)

    assert_receive {:runtime_request, request}
    assert request.thread_id == thread_id
    assert request.session_id == "web-local"
    assert request.active_app == :allbert

    eval =
      live_security_eval(
        fixture,
        if(request.active_app == :allbert and neutral_session?(Session.get("local", "web-local")),
          do: :denied,
          else: :allowed
        ),
        %{
          boundary: :workspace_launcher_destination,
          canvas_destination: "app:stocksage",
          actions_executed: [],
          active_app: request.active_app
        }
      )

    assert eval.decision == fixture.expected
  end

  test "app launcher selection renders hydrated StockSage workspace panels", %{conn: conn} do
    ensure_stocksage_app_registered()

    assert {:ok, analysis} =
             StockSage.Analyses.create_analysis(%{
               user_id: "local",
               symbol: "aapl",
               source: "manual",
               status: "completed",
               engine: "native",
               recommendation: "Buy",
               summary: "Constructive setup."
             })

    assert {:ok, _queue_entry} =
             StockSage.Queue.create_entry(%{
               user_id: "local",
               symbol: "msft",
               priority: "high",
               requested_for: ~D[2026-05-23]
             })

    assert {:ok, _outcome} =
             StockSage.Analyses.create_outcome(%{
               user_id: "local",
               analysis_id: analysis.id,
               symbol: "aapl",
               label: "win",
               return_pct: Decimal.new("4.2")
             })

    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element("#workspace-dest-app-stocksage")
    |> render_click()

    assert has_element?(view, "#workspace-shell[data-active-app='allbert']")
    assert has_element?(view, "#workspace-shell[data-canvas-destination='app:stocksage']")

    assert has_element?(
             view,
             "#workspace-node-workspace-panel-stocksage-stocksage_dashboard_panel-dashboard"
           )

    assert has_element?(
             view,
             "#workspace-node-workspace-panel-stocksage-stocksage_recent_analyses_panel-recent"
           )

    assert has_element?(
             view,
             "#workspace-node-workspace-panel-stocksage-stocksage_queue_panel-queue"
           )

    assert has_element?(
             view,
             "#workspace-node-workspace-panel-stocksage-stocksage_trends_panel-trends"
           )

    assert has_element?(view, ~s([data-stocksage-component="analysis_card"]))

    html = render(view)
    assert html =~ "AAPL analysis"
    assert html =~ "Constructive setup."
    assert html =~ "MSFT queued analysis"
    assert html =~ "StockSage outcome trends"
    refute html =~ "stocksage-nav"
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

  test "default runtime can activate a skill through LiveView", %{conn: conn} do
    Application.delete_env(:allbert_assist, Runtime)

    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Activate skill append-memory"})

    html = render_async(view, @runtime_async_timeout)

    assert has_element?(view, "#agent-response")
    assert html =~ "## Skill Context"
    assert html =~ "Name: append-memory"
    assert has_element?(view, "#agent-status")
    assert html =~ "completed"
  end

  test "default runtime renders URL summarization approval through LiveView", %{conn: conn} do
    Application.delete_env(:allbert_assist, Runtime)
    configure_external()

    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "check https://example.com/report and summarize it"})

    html = render_async(view, @runtime_async_timeout)

    assert has_element?(view, "#agent-response")
    assert html =~ "External network request is ready"
    assert has_element?(view, "#agent-status")
    assert html =~ "needs_confirmation"
    assert html =~ "Resource remote_url summarize_url summarize"
    assert html =~ "consumer=url_summarizer"
    assert has_element?(view, "#approval-handoff")
    assert has_element?(view, "#approval-approve:not([disabled])")
    assert has_element?(view, "#approval-approve[phx-disable-with='Approving']")
    assert [_pending] = Confirmations.list(status: :pending)
  end

  test "StockSage approval handoff keeps approve action enabled in agent UI", %{conn: conn} do
    Application.delete_env(:allbert_assist, Runtime)
    ensure_stocksage_app_registered()
    assert {:ok, _entry} = Session.set_active_app("local", "web-local", :stocksage)

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=app:stocksage")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "analyze AAPL"})

    html = render_async(view, @runtime_async_timeout)

    assert has_element?(view, "#approval-handoff")
    assert has_element?(view, "#approval-approve:not([disabled])")
    assert has_element?(view, "#approval-approve[phx-disable-with='Approving']")
    assert has_element?(view, "#approval-deny:not([disabled])")
    assert has_element?(view, "#approval-deny[phx-disable-with='Denying']")
    assert html =~ "run_analysis"

    pending =
      Confirmations.list(status: :pending)
      |> Enum.find(&(&1["target_action"]["name"] == "run_analysis"))

    assert pending
    assert pending["params_summary"]["ticker"] == "AAPL"
  end

  test "default runtime renders approval handoff and resolves denial through actions", %{
    conn: conn
  } do
    Application.delete_env(:allbert_assist, Runtime)
    configure_external()

    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Fetch https://example.com from the internet"})

    html = render_async(view, @runtime_async_timeout)

    assert has_element?(view, "#approval-handoff")
    assert html =~ "Approval Required"
    assert html =~ "external_network_request"
    assert html =~ "Resource remote_url external_service_request fetch"
    assert has_element?(view, "#approval-approve:not([disabled])")
    assert has_element?(view, "#approval-deny")
    assert has_element?(view, "#approval-details")
    assert has_element?(view, "#approval-approve[phx-disable-with='Approving']")

    [pending] = Confirmations.list(status: :pending)
    assert pending["target_action"]["name"] == "external_network_request"

    deny_html =
      view
      |> element("#approval-deny")
      |> render_click()

    assert deny_html =~ "Confirmation #{pending["id"]} is denied."
    refute has_element?(view, "#approval-handoff")
    refute has_element?(view, "#approval-approve")
    refute has_element?(view, "#approval-deny")
    assert has_element?(view, "#approval-result")
    assert {:ok, denied} = Confirmations.read(pending["id"])
    assert denied["status"] == "denied"
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/"], %{audit?: false})
  end

  defp configure_mcp_server(server_id, tool_allowlist) do
    assert {:ok, _setting} =
             Settings.put("mcp.servers.#{server_id}.enabled", false, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.#{server_id}.transport", "streamable_http", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put("mcp.servers.#{server_id}.base_url", "https://example.com/mcp", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put("mcp.servers.#{server_id}.tool_allowlist", tool_allowlist, %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put("mcp.servers.#{server_id}.confirmation", "required", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.#{server_id}.enabled", true, %{audit?: false})
  end

  defp start_workspace_bridge do
    name = :"workspace_live_sync_bridge_#{System.unique_integer([:positive])}"
    start_supervised!({SignalBridge, name: name})
  end

  defp subscribe_actions do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.action.completed")
  end

  defp receive_action_completed(action_name) do
    receive do
      {:signal, %{type: "allbert.action.completed", data: %{action_name: ^action_name}} = signal} ->
        signal

      {:signal, %{type: "allbert.action.completed"}} ->
        receive_action_completed(action_name)
    after
      1_000 -> flunk("expected action completion for #{action_name}")
    end
  end

  defp create_workspace_thread(text \\ "Workspace test thread") do
    assert {:ok, thread} = Conversations.create_general_thread("local", text)
    thread
  end

  defp workspace_thread_id(view) do
    html = render(view)
    assert [_, thread_id] = Regex.run(~r/data-thread-id="([^"]+)"/, html)
    thread_id
  end

  defp html_position(html, marker) do
    case :binary.match(html, marker) do
      {position, _length} -> position
      :nomatch -> flunk("expected rendered HTML to contain #{inspect(marker)}")
    end
  end

  defp ensure_stocksage_app_registered do
    plugin_registered? =
      match?({:ok, _entry}, AllbertAssist.Plugin.Registry.lookup("stocksage"))

    unless plugin_registered? do
      assert AllbertAssist.Plugin.Registry.register_module(StockSage.Plugin) in [
               {:ok, "stocksage"},
               {:error, {:plugin_id_taken, "stocksage"}}
             ]
    end

    app_registered? = AllbertAssist.App.Registry.known_app_id?(:stocksage)

    unless app_registered? do
      assert {:ok, :stocksage} = AllbertAssist.App.Registry.register(StockSage.App)
    end

    on_exit(fn ->
      unless app_registered?, do: AllbertAssist.App.Registry.unregister(:stocksage)
    end)
  end

  defp confirmation_attrs(id) do
    %{
      id: id,
      origin: %{actor: "local", channel: :live_view, surface: "/workspace"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{
        url: "https://example.com/settings-central",
        resource_refs: [external_ref("https://example.com/settings-central")]
      }
    }
  end

  defp external_ref(url) do
    %{
      resource_uri: ResourceURI.url!(url),
      origin_kind: :remote_url,
      canonical_id: url,
      operation_class: :external_service_request,
      access_mode: :fetch,
      scope: Scope.to_map(Scope.exact_url(url)),
      downstream_consumer: :req_http
    }
  end

  defp signed_envelope(attrs) do
    secret = SigningSecret.ensure!()

    attrs =
      Map.merge(
        %{
          surface: fragment_surface(:text, "Fragment body"),
          emitter_id: "AllbertAssist.Actions.Intent.DirectAnswer",
          user_id: "local",
          thread_id: "thr_test_default",
          scope: :canvas,
          kind: :text,
          emitted_at: ~U[2026-05-18 00:00:00Z]
        },
        attrs
      )

    assert {:ok, envelope} = Envelope.sign(attrs, secret)
    envelope
  end

  defp fragment_surface(component, body) do
    %Surface{
      id: :fragment,
      app_id: :allbert,
      label: "Fragment",
      path: "/workspace",
      kind: :canvas,
      status: :available,
      nodes: [
        %Node{
          id: "fragment-#{component}",
          component: component,
          props: %{title: "Fragment", body: body}
        }
      ],
      fallback_text: "Fragment fallback"
    }
  end

  defp stocksage_analysis_surface(analysis_id) do
    %Surface{
      id: :stocksage_analysis_card,
      app_id: :stocksage,
      label: "StockSage Analysis",
      path: "/apps/stocksage/analyses/#{analysis_id}",
      kind: :analysis,
      status: :available,
      nodes: [
        %Node{
          id: "analysis-#{analysis_id}",
          component: :analysis_card,
          props: %{
            title: "AAPL analysis completed",
            analysis_id: analysis_id,
            ticker: "AAPL",
            symbol: "AAPL",
            analysis_date: "2026-05-18",
            engine: "native",
            status: "completed",
            rating: "Overweight",
            recommendation: "Overweight",
            confidence: 0.82,
            summary: "Constructive setup.",
            route: "/apps/stocksage/analyses/#{analysis_id}"
          }
        }
      ],
      fallback_text: "AAPL analysis completed",
      metadata: %{source: "stocksage", fragment_id: "stocksage_analysis_#{analysis_id}"}
    }
  end

  defp persist_discovery_suggestion(manifest) do
    {:ok, candidate} =
      ToolCandidate.normalize(%{
        id: "remote_mcp:official:#{manifest["name"]}",
        name: manifest["name"],
        description: manifest["description"],
        source: :remote_mcp,
        provenance: %{provider: :official, remote_server_id: manifest["name"]}
      })

    assert {:ok, _record} = Discovery.upsert_candidate(candidate, %{registry_record: manifest})

    assert {:ok, report} =
             Discovery.evaluate_server(manifest, %{
               candidate_id: candidate.id,
               provider: "official"
             })

    assert {:ok, _report_record} = Discovery.upsert_evaluation_report(candidate.id, report)

    assert {:ok, _suggestion} =
             Discovery.upsert_suggestion(
               candidate.id,
               ToolCandidate.to_map(candidate),
               Discovery.evaluation_to_map(report)
             )

    {:ok, candidate}
  end

  defp render_until(view, text, attempts \\ 20)

  defp render_until(view, text, attempts) when attempts > 0 do
    html = render(view)

    if html =~ text do
      html
    else
      Process.sleep(50)
      render_until(view, text, attempts - 1)
    end
  end

  defp render_until(view, text, 0) do
    html = render(view)
    assert html =~ text
    html
  end

  defp render_until_missing(view, selector, attempts \\ 20)

  defp render_until_missing(view, selector, attempts) when attempts > 0 do
    if has_element?(view, selector) do
      Process.sleep(50)
      render_until_missing(view, selector, attempts - 1)
    else
      render(view)
    end
  end

  defp render_until_missing(view, selector, 0) do
    refute has_element?(view, selector)
    render(view)
  end

  defp live_security_eval(fixture, decision, trace) do
    %{
      decision: decision,
      trace:
        trace
        |> Map.put_new(:fixture_id, fixture.id)
        |> Map.put_new(:boundary, fixture.boundary),
      fixture: fixture
    }
  end

  defp neutral_session?({:error, :not_found}), do: true
  defp neutral_session?({:ok, %{active_app: nil}}), do: true
  defp neutral_session?(_session), do: false
end
