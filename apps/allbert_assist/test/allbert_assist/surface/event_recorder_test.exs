defmodule AllbertAssist.Surface.EventRecorderTest do
  use AllbertAssist.DataCase, async: false

  import Ecto.Query

  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Operator.Inspection
  alias AllbertAssist.Repo
  alias AllbertAssist.Surface.EventRecorder

  test "records non-channel inbound events and marks successful runtime results processed" do
    event =
      EventRecorder.record_inbound("live_view", %{
        external_event_id: "live_view:test-success",
        user_id: "local",
        session_id: "web-local",
        payload_summary: "hello"
      })

    assert %Event{channel: "live_view", provider: "allbert", status: "received"} = event

    assert :ok =
             EventRecorder.mark_result(event, {
               :ok,
               %{
                 status: :completed,
                 message: "done",
                 signal_id: "sig-1",
                 trace_id: "trace-1",
                 thread_id: "thr-1"
               }
             })

    stored = Repo.get!(Event, event.id)
    assert stored.status == "processed"
    assert stored.input_signal_id == "sig-1"
    assert stored.trace_id == "trace-1"
    assert stored.thread_id == "thr-1"
  end

  test "records rejected and failed surface events for operator audit" do
    rejected =
      EventRecorder.record_rejection(:openai_api, %{
        external_event_id: "openai_api:test-rejected",
        user_id: "client",
        reason: "invalid_request"
      })

    failed =
      EventRecorder.record_error(:mcp_http, %{external_event_id: "mcp_http:test-failed"}, :boom)

    assert %Event{channel: "openai_api", status: "rejected"} = rejected
    assert %Event{channel: "mcp_http", status: "failed", error: ":boom"} = failed

    report = Inspection.events(%{limit: 5})
    rendered = Inspection.render_events(report)

    assert rendered =~ "surface_id=openai_api"
    assert rendered =~ "surface_id=mcp_http"
  end

  test "marks denied runtime responses as rejected and error responses as failed" do
    denied = EventRecorder.record_inbound(:cli, %{external_event_id: "cli:test-denied"})
    failed = EventRecorder.record_inbound(:cli, %{external_event_id: "cli:test-error"})

    EventRecorder.mark_result(denied, {:ok, %{status: :denied, message: "no"}})
    EventRecorder.mark_result(failed, {:ok, %{status: :error, message: "bad"}})

    statuses =
      Repo.all(
        from event in Event,
          where: event.external_event_id in ["cli:test-denied", "cli:test-error"],
          select: {event.external_event_id, event.status, event.reason}
      )
      |> Map.new(fn {id, status, reason} -> {id, {status, reason}} end)

    assert statuses["cli:test-denied"] == {"rejected", "denied"}
    assert statuses["cli:test-error"] == {"failed", "error"}
  end
end
