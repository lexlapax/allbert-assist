defmodule AllbertAssistWeb.WorkspaceLiveTest do
  # v1.0.2 M4 external remainder: every test here deletes the fixture
  # `agent_runner` and drives the live default Runtime singleton — the real
  # agent runtime plus the provider endpoints and MCP/tool client supervision
  # it owns. That is a shared runtime resource the liveview_serial partition
  # runner does not own, so this file stays `lane: :external_runtime_serial`
  # (test-strategy.md lane taxonomy; v1.0.2 Locked Decisions 4 and 5). The
  # partition-safe workspace LiveView tests moved to
  # test/allbert_assist_web/live/workspace/ (v1.0.2 M4 split).
  use AllbertAssistWeb.ConnCase, async: false, lane: :external_runtime_serial
  use AllbertAssistWeb.WorkspaceLiveCase

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias AllbertAssist.{Confirmations, Conversations, Objectives, Runtime, Session, Settings}
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.TerminalTransitions

  @runtime_async_timeout 60_000

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

    # v0.61 M10.3 P1 — the runtime-response article and the latest timeline message
    # must not both claim id="agent-response"/"agent-status"; duplicate ids corrupt
    # LiveView DOM patching.
    assert length(Regex.scan(~r/id="agent-response"/, html)) <= 1
    assert length(Regex.scan(~r/id="agent-status"/, html)) <= 1
    assert length(Regex.scan(~r/id="agent-trace"/, html)) <= 1
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
    assert {:ok, _entry} = Session.set_active_app("local", live_view_session_id(), :stocksage)

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

  test "default runtime approval handoff dismisses without resolving confirmation", %{conn: conn} do
    Application.delete_env(:allbert_assist, Runtime)
    configure_external()

    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Fetch https://example.com from the internet"})

    html = render_async(view, @runtime_async_timeout)

    assert has_element?(view, "#approval-handoff")
    assert html =~ ~s(phx-window-keydown="dismiss_approval_handoff")
    assert html =~ ~s(phx-click-away="dismiss_approval_handoff")

    [pending] = Confirmations.list(status: :pending)

    view
    |> element("#approval-handoff")
    |> render_keydown(%{"key" => "Escape"})

    refute has_element?(view, "#approval-handoff")
    refute has_element?(view, "#approval-approve")
    refute has_element?(view, "#approval-deny")

    assert {:ok, still_pending} = Confirmations.read(pending["id"])
    assert still_pending["status"] == "pending"
  end

  test "attached Web renders and acknowledges one origin-thread fan-in report", %{conn: conn} do
    assert {:ok, thread} = Conversations.create_general_thread("local", "Fan-out origin")

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "local",
                 source_channel: "live_view",
                 source_surface: "channel",
                 source_thread_id: thread.id,
                 title: "Web fan-in",
                 objective: "Render in the origin thread"
               },
               ["research", "draft"]
             )

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")
    complete_fanout_children!(children)

    html = eventually_render(view, "Web fan-in — success")
    assert html =~ "✓ research — result 0"
    assert html =~ "✓ draft — result 1"
    assert has_element?(view, "#attached-fanout-report-#{parent.id}")

    assert has_element?(
             view,
             "#attached-fanout-report-#{parent.id}[data-canonical-message-id='#{Conversations.fanout_report_message_id(parent.id)}']"
           )

    assert render(element(view, "#workspace-objective-count-chip")) =~ "0 active"

    assert Fanout.parent_projection(parent).parent.report_delivery_state == "pending"

    render_hook(view, "ack_attached_fanout_report", %{"parent_id" => parent.id})

    assert Fanout.parent_projection(parent).parent.report_delivery_state == "delivered"
    refute has_element?(view, "#attached-fanout-report-#{parent.id}")

    assert [canonical_report] = Conversations.list_messages(thread)
    assert canonical_report.role == "assistant"
    assert canonical_report.metadata["parent_objective_id"] == parent.id

    send(
      view.pid,
      {:objective_event,
       Jido.Signal.new!("allbert.objectives.fanout.joined", %{parent_id: parent.id})}
    )

    duplicate_html = render(element(view, "#workspace-chat-timeline"))
    assert length(Regex.scan(~r/Web fan-in — success/, duplicate_html)) == 1

    assert {:ok, _ordinary_answer} =
             Conversations.append_assistant_message(thread, "The result of 2 + 2 is 4.")

    {:ok, remounted, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")
    remounted_timeline = render(element(remounted, "#workspace-chat-timeline"))

    assert remounted_timeline =~ "The result of 2 + 2 is 4."
    assert length(Regex.scan(~r/Web fan-in — success/, remounted_timeline)) == 1
    refute has_element?(remounted, "#attached-fanout-report-#{parent.id}")
  end

  test "a different Web thread does not consume a pending fan-in report", %{conn: conn} do
    assert {:ok, origin} = Conversations.create_general_thread("local", "Origin thread")
    assert {:ok, other} = Conversations.create_general_thread("local", "Other thread")

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "local",
                 source_channel: "live_view",
                 source_surface: "channel",
                 source_thread_id: origin.id,
                 title: "Thread-bound fan-in",
                 objective: "Do not leak across threads"
               },
               ["one", "two"]
             )

    {:ok, other_view, _html} = live(conn, ~p"/workspace?thread_id=#{other.id}")
    complete_fanout_children!(children)

    send(
      other_view.pid,
      {:objective_event,
       Jido.Signal.new!("allbert.objectives.fanout.joined", %{parent_id: parent.id})}
    )

    refute render(other_view) =~ "Thread-bound fan-in — success"
    assert Fanout.parent_projection(parent).parent.report_delivery_state == "pending"
  end

  test "connected remount reconciles a persisted but unacknowledged Web report", %{conn: conn} do
    assert {:ok, thread} = Conversations.create_general_thread("local", "Remount fan-in")

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "local",
                 source_channel: "live_view",
                 source_surface: "channel",
                 source_thread_id: thread.id,
                 title: "Remount recovery",
                 objective: "Recover before browser acknowledgement"
               },
               ["one", "two"]
             )

    complete_fanout_children!(children)
    assert Fanout.parent_projection(parent).parent.report_delivery_state == "pending"

    {:ok, view, html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    assert html =~ "Remount recovery — success"
    assert has_element?(view, "#attached-fanout-report-#{parent.id}")
    assert [_canonical_report] = Conversations.list_messages(thread)

    render_hook(view, "ack_attached_fanout_report", %{"parent_id" => parent.id})

    assert Fanout.parent_projection(parent).parent.report_delivery_state == "delivered"
    refute has_element?(view, "#attached-fanout-report-#{parent.id}")
  end

  test "canonical persistence failure renders no marker and leaves the report pending", %{
    conn: conn
  } do
    assert {:ok, thread} = Conversations.create_general_thread("local", "Closed origin")

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "local",
                 source_channel: "live_view",
                 source_surface: "channel",
                 source_thread_id: thread.id,
                 title: "Pending after write failure",
                 objective: "Do not acknowledge failed persistence"
               },
               ["one", "two"]
             )

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")
    assert {:ok, _completed_thread} = Conversations.complete_thread("local", thread.id)

    log =
      capture_log(fn ->
        complete_fanout_children!(children)

        Process.put(
          :canonical_persistence_failure_html,
          eventually_render(view, "could not be added to this conversation")
        )
      end)

    html = Process.delete(:canonical_persistence_failure_html)

    assert log =~ "live fan-in canonical persistence failed reason=:thread_completed"
    refute html =~ "Pending after write failure — success"
    refute has_element?(view, "#attached-fanout-report-#{parent.id}")
    assert Fanout.parent_projection(parent).parent.report_delivery_state == "pending"
    assert Conversations.list_messages(thread) == []
  end

  test "two Web fan-ins queued before browser acknowledgement remain independently deliverable",
       %{
         conn: conn
       } do
    assert {:ok, thread} = Conversations.create_general_thread("local", "Two Web fan-ins")

    frames =
      for title <- ["Web fan-in A", "Web fan-in B"] do
        assert {:ok, frame} =
                 Fanout.frame(
                   %{
                     user_id: "local",
                     source_channel: "live_view",
                     source_surface: "channel",
                     source_thread_id: thread.id,
                     title: title,
                     objective: "Render every joined report"
                   },
                   ["one", "two"]
                 )

        frame
      end

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")
    Enum.each(frames, &complete_fanout_children!(&1.children))

    _html = eventually_render(view, "Web fan-in A — success")
    html = eventually_render(view, "Web fan-in B — success")
    assert html =~ "Web fan-in B — success"

    for frame <- frames do
      assert has_element?(view, "#attached-fanout-report-#{frame.parent.id}")
      assert Fanout.parent_projection(frame.parent).parent.report_delivery_state == "pending"
    end

    [first, second] = frames

    render_hook(view, "ack_attached_fanout_report", %{"parent_id" => first.parent.id})

    assert Fanout.parent_projection(first.parent).parent.report_delivery_state == "delivered"
    assert Fanout.parent_projection(second.parent).parent.report_delivery_state == "pending"
    refute has_element?(view, "#attached-fanout-report-#{first.parent.id}")
    assert has_element?(view, "#attached-fanout-report-#{second.parent.id}")

    render_hook(view, "ack_attached_fanout_report", %{"parent_id" => second.parent.id})

    assert Fanout.parent_projection(second.parent).parent.report_delivery_state == "delivered"
  end

  test "same-thread non-Web fan-in and forged report acknowledgement remain pending", %{
    conn: conn
  } do
    assert {:ok, thread} = Conversations.create_general_thread("local", "Channel isolation")

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "local",
                 source_channel: "tui",
                 source_surface: "channel",
                 source_thread_id: thread.id,
                 title: "Wrong-channel fan-in",
                 objective: "Do not render in Web"
               },
               ["one", "two"]
             )

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")
    complete_fanout_children!(children)

    send(
      view.pid,
      {:objective_event,
       Jido.Signal.new!("allbert.objectives.fanout.joined", %{parent_id: parent.id})}
    )

    refute render(view) =~ "Wrong-channel fan-in — success"
    refute has_element?(view, "#attached-fanout-report-#{parent.id}")

    render_hook(view, "ack_attached_fanout_report", %{"parent_id" => parent.id})
    assert Fanout.parent_projection(parent).parent.report_delivery_state == "pending"
  end

  test "real Workspace kickoff acknowledgement uses the persisted live_view identity", %{
    conn: conn
  } do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("objectives.fanout.confirm_before_start", false, %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "first task; second task"})

    html = render_async(view, @runtime_async_timeout)
    assert html =~ "I split this into 2 tasks"
    assert render(element(view, "#agent-status")) =~ "Fan-out started"
    refute render(element(view, "#agent-status")) =~ "completed"

    parent = eventually_fanout_parent(thread_id)
    assert parent.source_channel == "live_view"
    assert parent.source_surface == "channel"
    assert parent.kickoff_delivery_state == "pending"
    assert Enum.all?(Fanout.children(parent), &(&1.status == "open"))
    assert has_element?(view, "#runtime-delivery-#{parent.id}")

    # This test owns presentation and receipt identity, not background run
    # execution. Reinstate the no-start barrier before exercising the ACK so no
    # Coordinator can outlive the test transaction.
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.confirm_before_start", true, %{audit?: false})

    render_hook(view, "ack_runtime_deliveries", %{"delivery_id" => "forged"})
    assert Fanout.parent_projection(parent).parent.kickoff_delivery_state == "pending"

    render_hook(view, "ack_runtime_deliveries", %{"delivery_id" => parent.id})

    assert Fanout.parent_projection(parent).parent.kickoff_delivery_state == "acknowledged"
    refute has_element?(view, "#runtime-delivery-#{parent.id}")
  end

  test "fan-out start confirmation remains visible instead of a running label", %{conn: conn} do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("objectives.fanout.confirm_before_start", true, %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "first task; second task"})

    html = render_async(view, @runtime_async_timeout)
    assert html =~ "I split this into 2 tasks"
    assert render(element(view, "#agent-status")) =~ "needs_confirmation"
    refute render(element(view, "#agent-status")) =~ "Fan-out started"

    parent = eventually_fanout_parent(thread_id)
    assert Enum.all?(Fanout.children(parent), &(&1.status == "open"))
    assert Enum.all?(Fanout.children(parent), &(&1.run_attempt_count == 0))
  end

  defp complete_fanout_children!(children) do
    Enum.each(children, fn child ->
      assert {:ok, _transition} =
               TerminalTransitions.terminalize_child(
                 child,
                 %{
                   status: "completed",
                   last_observation_summary: "result #{child.queue_position}",
                   completed_at: DateTime.utc_now()
                 },
                 "run_completed",
                 %{}
               )
    end)
  end

  defp eventually_render(view, expected, attempts \\ 100)

  defp eventually_render(view, expected, attempts) when attempts > 0 do
    html = render(view)

    if html =~ expected do
      html
    else
      Process.sleep(10)
      eventually_render(view, expected, attempts - 1)
    end
  end

  defp eventually_render(_view, expected, 0),
    do: flunk("workspace did not render #{inspect(expected)}")

  defp eventually_fanout_parent(thread_id, attempts \\ 100)

  defp eventually_fanout_parent(thread_id, attempts) when attempts > 0 do
    parent =
      Enum.find(Objectives.list_objectives("local"), fn objective ->
        objective.fanout_role == "parent" and objective.source_thread_id == thread_id
      end)

    case parent && Objectives.get_objective(parent.id) do
      {:ok, persisted} ->
        persisted

      _pending ->
        Process.sleep(10)
        eventually_fanout_parent(thread_id, attempts - 1)
    end
  end

  defp eventually_fanout_parent(_thread_id, 0),
    do: flunk("Workspace fan-out kickoff was not persisted")

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/"], %{audit?: false})
  end
end
