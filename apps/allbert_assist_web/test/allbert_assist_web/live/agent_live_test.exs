defmodule AllbertAssistWeb.AgentLiveTest do
  use AllbertAssistWeb.ConnCase, async: false

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

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
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

  test "mount renders workspace shell, chat fallback, and empty canvas placeholder", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/agent")
    thread_id = workspace_thread_id(view)

    assert has_element?(view, "#workspace-shell")

    assert has_element?(
             view,
             "#workspace-shell[data-user-id='local'][data-thread-id='#{thread_id}']"
           )

    assert has_element?(view, "#agent-workspace-renderer")
    assert has_element?(view, "#allbert-appbar")
    assert has_element?(view, "#workspace-active-app-chip")
    assert has_element?(view, "#workspace-thread-chip")
    assert has_element?(view, "#workspace-chat-region")
    assert has_element?(view, "#agent-form")
    assert has_element?(view, "#workspace-node-workspace-canvas-region")
    assert has_element?(view, "#workspace-component-workspace-canvas-region")
    assert html =~ "canvas"
    refute html =~ "component not implemented"
  end

  test "mount binds workspace to a real conversation thread", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent")
    thread_id = workspace_thread_id(view)

    assert String.starts_with?(thread_id, "thr_")
    assert {:ok, thread} = Conversations.get_thread("local", thread_id)
    assert thread.id == thread_id
  end

  test "mount treats nil thread query params as absent", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/agent?thread_id=nil")
    thread_id = workspace_thread_id(view)

    assert String.starts_with?(thread_id, "thr_")
    assert {:ok, thread} = Conversations.get_thread("local", thread_id)
    assert thread.id == thread_id
    refute html =~ "Workspace thread fallback"
    refute html =~ ~s({:thread_not_found, "nil"})
  end

  test "mount treats empty and null thread query params as absent", %{conn: conn} do
    for query <- ["thread_id=", "thread_id=null"] do
      {:ok, view, html} = live(conn, "/agent?#{query}")
      thread_id = workspace_thread_id(view)

      assert String.starts_with?(thread_id, "thr_")
      assert {:ok, thread} = Conversations.get_thread("local", thread_id)
      assert thread.id == thread_id
      refute html =~ "Workspace thread fallback"
      refute html =~ "workspace-thread-notice"
    end
  end

  test "mount recovers stale explicit thread query params quietly", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/agent?thread_id=thr_missing_manual")
    thread_id = workspace_thread_id(view)

    assert String.starts_with?(thread_id, "thr_")
    assert thread_id != "thr_missing_manual"
    assert {:ok, thread} = Conversations.get_thread("local", thread_id)
    assert thread.id == thread_id
    assert has_element?(view, "#workspace-thread-notice[role='status']")
    assert html =~ "Started a new workspace thread"
    assert html =~ "thr_missing_manual"
    refute has_element?(view, "#agent-error")
    refute html =~ "Workspace thread fallback"
    refute html =~ ~s({:thread_not_found, "thr_missing_manual"})
  end

  test "mount applies workspace theme from settings", %{conn: conn} do
    assert {:ok, _setting} = Settings.put("workspace.theme", "dark", %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/agent")

    assert has_element?(view, "#workspace-shell[data-theme='dark']")
  end

  test "workspace theme toggle persists dark mode across reload", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent")
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
    assert {:ok, "dark"} = Settings.get("workspace.theme")
    assert has_element?(view, "#workspace-shell[data-theme='dark'][data-workspace-theme='dark']")

    assert has_element?(
             view,
             "#workspace-theme-toggle[data-current-theme='dark'][data-next-theme='light']"
           )

    {:ok, reloaded, _html} = live(conn, ~p"/agent")
    assert has_element?(reloaded, "#workspace-shell[data-theme='dark']")
  end

  test "workspace mobile tab toggle switches active section", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent")

    assert has_element?(view, "#workspace-shell[data-mobile-tab='chat']")
    assert has_element?(view, "#workspace-mobile-tabs[role='tablist']")
    assert has_element?(view, "#workspace-mobile-tab-chat[aria-selected='true']")
    assert has_element?(view, "#workspace-mobile-tab-canvas[aria-selected='false']")

    html =
      view
      |> element("#workspace-mobile-tab-canvas")
      |> render_click()

    assert html =~ ~s(data-mobile-tab="canvas")
    assert has_element?(view, "#workspace-mobile-tab-chat[aria-selected='false']")
    assert has_element?(view, "#workspace-mobile-tab-canvas[aria-selected='true']")

    html =
      view
      |> element("#workspace-mobile-tab-ephemeral")
      |> render_click()

    assert html =~ ~s(data-mobile-tab="ephemeral")
    assert has_element?(view, "#workspace-mobile-tab-ephemeral[aria-selected='true']")
  end

  test "mount configures workspace offline service worker", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent")

    assert has_element?(
             view,
             "#workspace-shell[data-offline-enabled='true'][data-service-worker-url='/workspace-sw.js'][data-service-worker-scope='/agent'][data-offline-shell-url='/workspace-offline.html']"
           )

    assert has_element?(view, "#workspace-offline-banner[hidden][data-state='online']")
  end

  test "offline disabled setting shows disabled workspace banner", %{conn: conn} do
    assert {:ok, _setting} =
             Settings.put("workspace.offline.enabled", false, %{audit?: false})

    {:ok, view, html} = live(conn, ~p"/agent")

    assert has_element?(view, "#workspace-shell[data-offline-enabled='false']")
    assert has_element?(view, "#workspace-offline-banner[data-state='disabled']")
    refute has_element?(view, "#workspace-offline-banner[hidden]")
    assert html =~ "Offline mode disabled."
  end

  test "mount applies high contrast workspace variant", %{conn: conn} do
    assert {:ok, _setting} = Settings.put("workspace.theme", "dark", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("workspace.accessibility.high_contrast", true, %{audit?: false})

    {:ok, view, html} = live(conn, ~p"/agent")

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

    {:ok, view, html} = live(conn, ~p"/agent")

    assert html =~ "workspace-reduce-motion"
    assert html =~ ~s(data-reduce-motion="true")

    assert has_element?(
             view,
             "#workspace-shell.workspace-reduce-motion[data-reduce-motion='true']"
           )
  end

  test "renders emitted canvas fragments through the workspace shell", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent")
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
    {:ok, view, _html} = live(conn, ~p"/agent")
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

    {:ok, view, _html} = live(conn, ~p"/agent?thread_id=#{thread.id}")
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

  test "ephemeral lifecycle events fan out open and close to sibling tabs", %{conn: conn} do
    start_workspace_bridge()
    thread = create_workspace_thread()

    {:ok, first_tab, _html} = live(conn, ~p"/agent?thread_id=#{thread.id}")
    {:ok, second_tab, _html} = live(conn, ~p"/agent?thread_id=#{thread.id}")

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
    {:ok, view, _html} = live(conn, ~p"/agent")
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

    assert html =~ "Workspace notices"
    assert html =~ "1 older tile(s) archived"
    assert {:ok, []} = Workspace.canvas_tiles(thread_id, "local")
  end

  test "ignores fragments for a different thread", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent")
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

    {:ok, first_tab, _html} = live(conn, ~p"/agent")
    thread_id = workspace_thread_id(first_tab)
    {:ok, second_tab, _html} = live(conn, ~p"/agent?thread_id=#{thread_id}")

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

    {:ok, first_tab, _html} = live(conn, ~p"/agent")
    thread_id = workspace_thread_id(first_tab)

    tabs =
      for _index <- 1..3 do
        assert {:ok, view, _html} = live(conn, ~p"/agent?thread_id=#{thread_id}")
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

    {:ok, view, html} = live(conn, ~p"/agent?thread_id=#{thread.id}")
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

    {:ok, view, _html} = live(conn, ~p"/agent?thread_id=#{thread.id}")

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

    {:ok, view, _html} = live(conn, ~p"/agent?thread_id=#{thread.id}")

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

    {:ok, view, _html} = live(conn, ~p"/agent?thread_id=#{thread.id}")

    refute has_element?(view, "#workspace-tile-editor-#{tile.id}")

    render_hook(view, :workspace_tile_editor_sync, %{
      "tile_id" => tile.id,
      "update" => "AQID",
      "state_vector" => "BAUG",
      "snapshot" => "read-only analysis"
    })

    assert_reply(view, %{status: "rejected", reason: ":unsupported_tile_kind"})
  end

  test "submits prompts through the runtime boundary", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/agent")
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
    assert html =~ "Status: completed"
    assert has_element?(view, "#agent-signal")
  end

  test "submits explicit active app context through the runtime boundary", %{conn: conn} do
    ensure_stocksage_app_registered()

    {:ok, view, _html} = live(conn, ~p"/agent?app_id=stocksage")
    thread_id = workspace_thread_id(view)

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "analyze AAPL"})

    _html = render_async(view, @runtime_async_timeout)

    assert_receive {:runtime_request, request}
    assert request.thread_id == thread_id
    assert request.session_id == "web-local"
    assert request.active_app == :stocksage
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

    {:ok, view, html} = live(conn, ~p"/agent")

    assert html =~ "Analyze AAPL"
    assert has_element?(view, "#objective-badge-#{objective.id}")
  end

  test "default runtime can activate a skill through LiveView", %{conn: conn} do
    Application.delete_env(:allbert_assist, Runtime)

    {:ok, view, _html} = live(conn, ~p"/agent")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Activate skill append-memory"})

    html = render_async(view, @runtime_async_timeout)

    assert has_element?(view, "#agent-response")
    assert html =~ "## Skill Context"
    assert html =~ "Name: append-memory"
    assert html =~ "Status: completed"
  end

  test "default runtime renders URL summarization approval through LiveView", %{conn: conn} do
    Application.delete_env(:allbert_assist, Runtime)
    configure_external()

    {:ok, view, _html} = live(conn, ~p"/agent")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "check https://example.com/report and summarize it"})

    html = render_async(view, @runtime_async_timeout)

    assert has_element?(view, "#agent-response")
    assert html =~ "External network request is ready"
    assert html =~ "Status: needs_confirmation"
    assert html =~ "Resource remote_url summarize_url summarize"
    assert html =~ "consumer=url_summarizer"
    assert has_element?(view, "#approval-handoff")
    assert [_pending] = Confirmations.list(status: :pending)
  end

  test "default runtime renders approval handoff and resolves denial through actions", %{
    conn: conn
  } do
    Application.delete_env(:allbert_assist, Runtime)
    configure_external()

    {:ok, view, _html} = live(conn, ~p"/agent")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Fetch https://example.com from the internet"})

    html = render_async(view, @runtime_async_timeout)

    assert has_element?(view, "#approval-handoff")
    assert html =~ "Approval Required"
    assert html =~ "external_network_request"
    assert html =~ "Resource remote_url external_service_request fetch"
    assert has_element?(view, "#approval-approve")
    assert has_element?(view, "#approval-deny")
    assert has_element?(view, "#approval-details")

    [pending] = Confirmations.list(status: :pending)
    assert pending["target_action"]["name"] == "external_network_request"

    deny_html =
      view
      |> element("#approval-deny")
      |> render_click()

    assert deny_html =~ "Confirmation #{pending["id"]} is denied."
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

  defp start_workspace_bridge do
    name = :"agent_live_sync_bridge_#{System.unique_integer([:positive])}"
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

  defp ensure_stocksage_app_registered do
    registered? = AllbertAssist.App.Registry.known_app_id?(:stocksage)

    unless registered? do
      assert AllbertAssist.Plugin.Registry.register_module(StockSage.Plugin) in [
               {:ok, "stocksage"},
               {:error, {:plugin_id_taken, "stocksage"}}
             ]

      assert {:ok, :stocksage} = AllbertAssist.App.Registry.register(StockSage.App)
    end

    on_exit(fn -> unless registered?, do: AllbertAssist.App.Registry.unregister(:stocksage) end)
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
      path: "/agent",
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
end
