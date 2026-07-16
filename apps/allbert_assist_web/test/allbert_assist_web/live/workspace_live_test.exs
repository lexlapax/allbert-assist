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

  import Phoenix.LiveViewTest

  alias AllbertAssist.{Confirmations, Runtime, Session, Settings}

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

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/"], %{audit?: false})
  end
end
