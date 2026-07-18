defmodule AllbertAssistWeb.WorkspaceDestinationsTest do
  use AllbertAssistWeb.ConnCase, async: false
  use AllbertAssistWeb.WorkspaceLiveCase

  import Phoenix.LiveViewTest

  alias AllbertAssist.{Confirmations, Marketplace, Session, Settings, Workspace}

  alias AllbertAssist.Actions.Settings.SetNotesRoot
  alias AllbertAssist.Intent.Handoff
  alias AllbertAssist.Intent.Router.DescriptorStore
  alias AllbertAssist.McpRegistryFixtures
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertAssist.Tools.Discovery
  alias AllbertAssist.Tools.ToolCandidate
  alias AllbertAssist.Workspace.Emitters, as: WorkspaceEmitters
  alias AllbertAssistWeb.Workspace.Components.OperatorPanels

  @runtime_async_timeout 60_000

  test "operator panel destinations are routable by URL", %{conn: conn} do
    thread = create_workspace_thread("Operator panels")

    for {destination, panel_id} <- [
          {"workspace:intents", "workspace-intents-panel"},
          {"workspace:models", "workspace-models-panel"},
          {"workspace:surface_policy", "workspace-surface-policy-panel"}
        ] do
      {:ok, view, _html} =
        live(conn, ~p"/workspace?thread_id=#{thread.id}&destination=#{destination}")

      assert has_element?(
               view,
               "#workspace-shell[data-canvas-destination='#{destination}'][data-canvas-drawer='open']"
             )

      assert has_element?(view, "##{panel_id}")
    end
  end

  # v0.65 M3: `workspace:notes` is a first-class workspace destination — a "Notes"
  # nav item + named destination + page title — that renders the notes/files app's
  # own `workspace_panel_surfaces` (list + detail), reachable without a raw URL.
  test "v0.65 M3: the Notes nav item is present in the operator sidebar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    assert has_element?(
             view,
             "#operator-nav-notes[href='/workspace?destination=workspace:notes']",
             "Notes"
           )
  end

  test "v0.65 M3: the workspace:notes destination searches and reads through the panel", %{
    conn: conn,
    root: root
  } do
    notes_root = Path.join(root, "notes")
    File.mkdir_p!(notes_root)

    File.write!(
      Path.join(notes_root, "m3-fixture.md"),
      "# Allbert Notes M3 Fixture\n\nGrounded local-knowledge note for the workspace:notes panel.\n"
    )

    ensure_notes_files_app_registered()
    assert {:ok, %{status: :completed}} = SetNotesRoot.run(%{path: notes_root}, action_context())

    thread = create_workspace_thread("Notes destination")

    {:ok, view, _html} =
      live(conn, ~p"/workspace?thread_id=#{thread.id}&destination=workspace:notes")

    # Reaches the notes destination — does NOT degrade to the output canvas.
    assert has_element?(
             view,
             "#workspace-shell[data-canvas-destination='workspace:notes'][data-canvas-drawer='open']"
           )

    refute has_element?(view, "#workspace-shell[data-canvas-destination='output']")

    assert has_element?(
             view,
             "#workspace-notes-panel[data-action-source='actions-runner']"
           )

    assert has_element?(view, "#workspace-notes-search-form")

    view
    |> form("#workspace-notes-search-form", query: "Grounded local-knowledge")
    |> render_submit()

    assert render(view) =~ "Allbert Notes M3 Fixture"

    view
    |> element("#workspace-note-open-m3-fixture-md")
    |> render_click()

    detail = render(view)
    assert detail =~ "Grounded local-knowledge note for the workspace:notes panel."
    assert detail =~ "resource_refs=1"
  end

  # v0.65 M4: `workspace:memory` is an interactive review destination — a "Memory"
  # nav item + named destination — that lists unreviewed memory candidates and
  # dispatches the existing keep/reject/delete memory actions through the Runner.
  # It adds no new authority: keep/reject route through `review_memory_entry` and
  # delete through the confirmation-gated `delete_memory_entry` archive.
  test "v0.65 M4: the Memory nav item is present in the operator sidebar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")

    assert has_element?(
             view,
             "#operator-nav-memory[href='/workspace?destination=workspace:memory']",
             "Memory"
           )
  end

  test "v0.65 M4: keep/reject/delete drive the review loop from workspace:memory", %{conn: conn} do
    keep_entry = seed_unreviewed_memory("Keep this milestone note.")
    reject_entry = seed_unreviewed_memory("Reject this stray note.")
    delete_entry = seed_unreviewed_memory("Delete this note entirely.")
    _other_user_entry = seed_unreviewed_memory("Bob should not appear here.", "bob")

    assert {:ok, local_candidates} =
             AllbertAssist.Memory.list_entries(review_status: :unreviewed, user_id: "local")

    assert MapSet.new(Enum.map(local_candidates, & &1.path)) ==
             MapSet.new([keep_entry.path, reject_entry.path, delete_entry.path])

    thread = create_workspace_thread("Memory review")

    {:ok, view, _html} =
      live(conn, ~p"/workspace?thread_id=#{thread.id}&destination=workspace:memory")

    # Reaches the interactive memory panel and lists the unreviewed candidates.
    # v1.0.2 M8.6 drift-fix: the memory card loads candidates asynchronously
    # (force_load?), so wait for the loaded content instead of racing the
    # first render (the recorded first-roll liveview flake family).
    assert has_element?(view, "#workspace-memory-panel")
    assert render_until(view, "Keep this milestone note.")
    refute render(view) =~ "Bob should not appear here."

    # Keep dispatches review_memory_entry status=kept.
    view
    |> element("#workspace-memory-keep-#{memory_safe_id(keep_entry.path)}")
    |> render_click()

    assert {:ok, kept} = AllbertAssist.Memory.list_entries(review_status: :kept, user_id: "local")
    assert Enum.map(kept, & &1.path) == [keep_entry.path]

    # Reject dispatches review_memory_entry status=flagged (a different candidate).
    view
    |> element("#workspace-memory-reject-#{memory_safe_id(reject_entry.path)}")
    |> render_click()

    assert {:ok, flagged} =
             AllbertAssist.Memory.list_entries(review_status: :flagged, user_id: "local")

    assert Enum.map(flagged, & &1.path) == [reject_entry.path]

    # Delete runs the confirmation-gated archive (create+approve); the entry leaves
    # active memory rather than being hard-deleted.
    assert File.exists?(delete_entry.path)

    view
    |> element("#workspace-memory-delete-#{memory_safe_id(delete_entry.path)}")
    |> render_click()

    refute File.exists?(delete_entry.path)
  end

  test "the channels destination renders the populated read-only channels panel", %{conn: conn} do
    thread = create_workspace_thread("Channels")

    {:ok, view, html} =
      live(conn, ~p"/workspace?thread_id=#{thread.id}&destination=workspace:channels")

    # Reaches the channels destination — does NOT degrade to the output canvas.
    assert has_element?(
             view,
             "#workspace-shell[data-canvas-destination='workspace:channels'][data-canvas-drawer='open']"
           )

    refute has_element?(view, "#workspace-shell[data-canvas-destination='output']")

    # The panel is the real action-backed channels_panel (M10.3 P0-7), not the old
    # static placeholder — it reads channel status through the registered action
    # boundary and shows a real inventory row or an honest empty state.
    assert has_element?(
             view,
             "#workspace-channels-panel[data-workspace-component='channels_panel']"
           )

    assert has_element?(view, "#workspace-channels-panel[data-action-source='actions-runner']")
    assert has_element?(view, "#workspace-channels-empty") or html =~ "workspace-channel-"
    refute html =~ "Connected channels appear here once configured."
  end

  test "intents panel promotion shows gate rejection without mutating review descriptor", %{
    conn: conn
  } do
    assert {:ok, _review_path} =
             DescriptorStore.put(:review, %{
               app_id: :allbert,
               action_name: "list_channels",
               label: "List channels",
               examples: ["list my channels"],
               synonyms: ["channels"],
               required_slots: [:channel]
             })

    thread = create_workspace_thread("Intent gate")

    {:ok, view, html} =
      live(conn, ~p"/workspace?thread_id=#{thread.id}&destination=workspace:intents")

    assert html =~ "Eval Gate"
    assert html =~ "deferred"
    assert has_element?(view, "#workspace-intent-promote-list_channels")

    html =
      view
      |> element("#workspace-intent-promote-list_channels")
      |> render_click()

    assert html =~ "gate failed"
    assert html =~ "Intent action status: rejected"
    assert has_element?(view, "#workspace-intent-promote-list_channels")

    assert {:ok, review_path} = DescriptorStore.path(:review, :allbert, "list_channels")
    assert File.exists?(review_path)

    assert {:ok, generated_path} = DescriptorStore.path(:generated, :allbert, "list_channels")
    refute File.exists?(generated_path)
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

  test "marketplace destination renders catalog and routes install affordance through actions",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:marketplace")

    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:marketplace']")
    assert has_element?(view, "#workspace-dest-workspace-marketplace")
    assert has_element?(view, "[data-workspace-component='panel']", "Marketplace Catalog")
    assert has_element?(view, "[data-workspace-component='settings_card']", "Research Helpers")

    assert has_element?(
             view,
             "button[data-workspace-component='action_button']" <>
               "[phx-value-action-name='install_marketplace_bundle']" <>
               "[phx-value-entry-id='allbert/research-helpers']",
             "Install"
           )

    view
    |> element(
      "button[data-workspace-component='action_button']" <>
        "[phx-value-action-name='install_marketplace_bundle']" <>
        "[phx-value-entry-id='allbert/research-helpers']",
      "Install"
    )
    |> render_click()

    assert Confirmations.list(status: "pending") == []
    assert {:ok, [installed]} = Marketplace.list_installed()
    assert installed["entry_id"] == "allbert/research-helpers"
    assert installed["install_state"] == "disabled_untrusted"

    assert has_element?(
             view,
             "button[data-workspace-component='action_button']" <>
               "[phx-value-action-name='rollback_marketplace_install']" <>
               "[phx-value-entry-id='allbert/research-helpers']",
             "Rollback"
           )
  end

  test "calendar panel create-event affordance routes through Approval Handoff", %{conn: conn} do
    configure_mcp_server("calendar", ["create_event"])

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:calendar")

    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:calendar']")
    assert has_element?(view, "#workspace-dest-workspace-calendar")
    assert has_element?(view, "[data-workspace-component='settings_card']", "Server calendar")
    assert has_element?(view, "form[data-workspace-component='mcp_effect_form']", "Create Event")

    view
    |> form("form[data-workspace-component='mcp_effect_form']", %{
      "summary" => "Planning sync",
      "start" => "2026-06-01T09:00",
      "end" => "2026-06-01T09:30",
      "calendar_id" => "primary"
    })
    |> render_submit()

    assert has_element?(view, "#approval-handoff")
    assert [confirmation] = Confirmations.list(status: "pending")
    assert get_in(confirmation, ["target_action", "name"]) == "mcp_call_tool"
    assert get_in(confirmation, ["params_summary", "server_id"]) == "calendar"
    assert get_in(confirmation, ["params_summary", "tool_name"]) == "create_event"

    assert get_in(confirmation, ["params_summary", "arguments", "keys"]) == [
             "calendar_id",
             "end",
             "source",
             "start",
             "summary"
           ]

    assert get_in(confirmation, ["resume_params_ref", "arguments", "summary"]) == "Planning sync"
    assert get_in(confirmation, ["resume_params_ref", "arguments", "start"]) == "2026-06-01T09:00"
    assert get_in(confirmation, ["resume_params_ref", "arguments", "end"]) == "2026-06-01T09:30"
    assert get_in(confirmation, ["resume_params_ref", "arguments", "calendar_id"]) == "primary"
  end

  test "mail panel reply affordance routes through Approval Handoff", %{conn: conn} do
    configure_mcp_server("mail", ["reply_message"])

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:mail")

    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:mail']")
    assert has_element?(view, "#workspace-dest-workspace-mail")
    assert has_element?(view, "[data-workspace-component='settings_card']", "Server mail")
    assert has_element?(view, "form[data-workspace-component='mcp_effect_form']", "Reply")

    view
    |> form("form[data-workspace-component='mcp_effect_form']", %{
      "message_id" => "msg_123",
      "body" => "Thanks for the update."
    })
    |> render_submit()

    assert has_element?(view, "#approval-handoff")
    assert [confirmation] = Confirmations.list(status: "pending")
    assert get_in(confirmation, ["target_action", "name"]) == "mcp_call_tool"
    assert get_in(confirmation, ["params_summary", "server_id"]) == "mail"
    assert get_in(confirmation, ["params_summary", "tool_name"]) == "reply_message"

    assert get_in(confirmation, ["params_summary", "arguments", "keys"]) == [
             "body",
             "message_id",
             "source"
           ]

    assert get_in(confirmation, ["resume_params_ref", "arguments", "message_id"]) == "msg_123"

    assert get_in(confirmation, ["resume_params_ref", "arguments", "body"]) ==
             "Thanks for the update."
  end

  test "github panel comment affordance routes through Approval Handoff", %{conn: conn} do
    configure_mcp_server("github", ["create_issue_comment"])

    {:ok, view, _html} = live(conn, ~p"/workspace?destination=workspace:github")

    assert has_element?(view, "#workspace-shell[data-canvas-destination='workspace:github']")
    assert has_element?(view, "#workspace-dest-workspace-github")
    assert has_element?(view, "[data-workspace-component='settings_card']", "Server github")
    assert has_element?(view, "form[data-workspace-component='mcp_effect_form']", "Comment")

    view
    |> form("form[data-workspace-component='mcp_effect_form']", %{
      "target" => "lexlapax/allbert-assist#42",
      "body" => "Reviewed from the workspace."
    })
    |> render_submit()

    assert has_element?(view, "#approval-handoff")
    assert [confirmation] = Confirmations.list(status: "pending")
    assert get_in(confirmation, ["target_action", "name"]) == "mcp_call_tool"
    assert get_in(confirmation, ["params_summary", "server_id"]) == "github"
    assert get_in(confirmation, ["params_summary", "tool_name"]) == "create_issue_comment"

    assert get_in(confirmation, ["params_summary", "arguments", "keys"]) == [
             "body",
             "source",
             "target"
           ]

    assert get_in(confirmation, ["resume_params_ref", "arguments", "target"]) ==
             "lexlapax/allbert-assist#42"

    assert get_in(confirmation, ["resume_params_ref", "arguments", "body"]) ==
             "Reviewed from the workspace."
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
    assert {:ok, _entry} = Session.set_active_app("local", live_view_session_id(), :stocksage)

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
    assert {:ok, %{active_app: nil}} = Session.get("local", live_view_session_id())
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
    assert request.session_id == live_view_session_id()
    assert request.active_app == :allbert

    eval =
      live_security_eval(
        fixture,
        if(
          request.active_app == :allbert and
            neutral_session?(Session.get("local", live_view_session_id())),
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
    assert neutral_session?(Session.get("local", live_view_session_id()))
    assert has_element?(view, "#workspace-shell[data-active-app='allbert']")
    assert has_element?(view, "#workspace-shell[data-canvas-destination='app:stocksage']")
    assert has_element?(view, "#workspace-dest-app-stocksage[aria-pressed='true']")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "analyze CIEN"})

    _html = render_async(view, @runtime_async_timeout)

    assert_receive {:runtime_request, request}
    assert request.thread_id == thread_id
    assert request.session_id == live_view_session_id()
    assert request.active_app == :allbert

    eval =
      live_security_eval(
        fixture,
        if(
          request.active_app == :allbert and
            neutral_session?(Session.get("local", live_view_session_id())),
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

  # v0.65 M4: seed an unreviewed memory candidate owned by the default workspace
  # operator ("local") so the workspace:memory panel can keep/reject/delete it.
  defp seed_unreviewed_memory(summary, actor \\ "local") do
    assert {:ok, entry} =
             AllbertAssist.Memory.append(%{
               category: :notes,
               body: summary,
               summary: summary,
               actor: actor,
               agent: "test",
               channel: :test,
               source_signal_id: "sig-#{System.unique_integer([:positive])}"
             })

    entry
  end

  defp memory_safe_id(path) do
    OperatorPanels.safe_id(path)
  end

  defp ensure_notes_files_app_registered do
    plugin_registered? =
      match?({:ok, _entry}, AllbertAssist.Plugin.Registry.lookup("allbert.notes_files"))

    unless plugin_registered? do
      assert {:ok, "allbert.notes_files"} =
               AllbertAssist.Plugin.Registry.register_module(AllbertNotesFiles.Plugin)
    end

    app_registered? = AllbertAssist.App.Registry.known_app_id?(:notes_files)

    unless app_registered? and notes_files_surface_provider_registered?() do
      AllbertAssist.App.Registry.unregister(:notes_files)
      assert {:ok, :notes_files} = AllbertAssist.App.Registry.register(AllbertNotesFiles.App)
    end

    on_exit(fn ->
      unless app_registered?, do: AllbertAssist.App.Registry.unregister(:notes_files)
    end)
  end

  defp notes_files_surface_provider_registered? do
    AllbertAssist.App.Registry.registered_surface_providers()
    |> Enum.any?(fn provider ->
      Map.get(provider, :app_id) == :notes_files and
        Map.get(provider, :module) == AllbertNotesFiles.App
    end)
  end

  defp action_context do
    ContextBuilder.live_view_context(%{user_id: "local"}, surface: "/workspace")
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
