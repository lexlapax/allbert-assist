defmodule AllbertAssist.PublicProtocol.ResultReadbackTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.PublicProtocol.CallResult
  alias AllbertAssist.PublicProtocol.ResultReadback
  alias AllbertAssist.PublicProtocol.ResultReadbackSweeper

  @now ~U[2026-06-09 12:00:00Z]

  test "client gets pending before approval and approved result after confirmation resolution" do
    assert {:ok, call_result} =
             ResultReadback.create(
               %{
                 surface: "mcp_http",
                 client_id: "claude",
                 action_label: "run_shell_command",
                 confirmation_id: "conf_public_1",
                 trace_id: "trace_public_1",
                 trace_metadata: %{api_key: "sk-test", phase: "pending"}
               },
               now: @now,
               ttl_ms: 3_600_000
             )

    assert {:ok, pending} =
             ResultReadback.get_for_client(call_result.id, "mcp_http", "claude", now: @now)

    assert pending.status == :pending
    refute Map.has_key?(pending, :result)
    refute inspect(pending) =~ "confirmation_id"

    confirmation_record = %{
      "id" => "conf_public_1",
      "status" => "approved",
      "resolved_at" => DateTime.to_iso8601(DateTime.add(@now, 60, :second)),
      "operator_resolution" => %{
        "target_status" => "completed",
        "target_result" => %{
          "status" => "completed",
          "message" => "done",
          "api_key" => "sk-test"
        }
      }
    }

    assert {:ok, 1} = ResultReadback.sync_confirmation(confirmation_record, now: @now)

    assert {:ok, approved} =
             ResultReadback.get_for_client(call_result.id, "mcp_http", "claude", now: @now)

    assert approved.status == :approved_with_result
    assert approved.result["message"] == "done"
    assert approved.result["api_key"] == "[REDACTED]"
    refute inspect(approved) =~ "operator_resolution"
  end

  test "client cannot read another client's public call id" do
    assert {:ok, call_result} =
             ResultReadback.create(
               %{
                 surface: "openai_api",
                 client_id: "local",
                 action_label: "direct_answer"
               },
               now: @now,
               ttl_ms: 3_600_000
             )

    assert {:error, :not_authorized} =
             ResultReadback.get_for_client(call_result.id, "openai_api", "other", now: @now)

    assert {:ok, response} =
             Runner.run(
               "get_public_call_result",
               %{id: call_result.id},
               %{public_protocol: %{surface: "openai_api", client_id: "other"}}
             )

    assert response.status == :denied
    assert response.public_call_result.error == :not_authorized
    refute Map.has_key?(response.public_call_result, :result)
  end

  test "denied confirmations return denied metadata without result bytes" do
    assert {:ok, call_result} =
             ResultReadback.create(
               %{
                 surface: "mcp_stdio",
                 client_id: "stdio-client",
                 confirmation_id: "conf_public_denied"
               },
               now: @now,
               ttl_ms: 3_600_000
             )

    confirmation_record = %{
      "id" => "conf_public_denied",
      "status" => "denied",
      "resolved_at" => DateTime.to_iso8601(DateTime.add(@now, 30, :second)),
      "operator_resolution" => %{
        "resolution_reason" => "not allowed",
        "target_result" => %{"secret" => "should not leak"}
      }
    }

    assert {:ok, 1} = ResultReadback.sync_confirmation(confirmation_record, now: @now)

    assert {:ok, denied} =
             ResultReadback.get_for_client(
               call_result.id,
               "mcp_stdio",
               "stdio-client",
               now: @now
             )

    assert denied.status == :denied
    assert denied.error["reason"] == "not allowed"
    refute Map.has_key?(denied, :result)
    refute inspect(denied) =~ "should not leak"
  end

  test "expired readback entries return expired and clear result bytes" do
    assert {:ok, call_result} =
             ResultReadback.create(
               %{
                 surface: "acp_stdio",
                 client_id: "zed",
                 result: %{message: "stale result"}
               },
               now: @now,
               ttl_ms: 1_000
             )

    expired_now = DateTime.add(@now, 2, :second)

    assert {:ok, expired} =
             ResultReadback.get_for_client(
               call_result.id,
               "acp_stdio",
               "zed",
               now: expired_now
             )

    assert expired.status == :expired
    refute Map.has_key?(expired, :result)
    refute inspect(expired) =~ "stale result"
  end

  test "sweeper expires only entries past their ttl" do
    assert {:ok, expired} =
             ResultReadback.create(
               %{surface: "mcp_http", client_id: "claude", action_label: "old"},
               now: @now,
               ttl_ms: 500
             )

    assert {:ok, fresh} =
             ResultReadback.create(
               %{surface: "mcp_http", client_id: "claude", action_label: "fresh"},
               now: @now,
               ttl_ms: 60_000
             )

    assert {:ok, 1} = ResultReadback.sweep_expired(now: DateTime.add(@now, 2, :second))

    assert {:ok, old_view} =
             ResultReadback.get_for_client(expired.id, "mcp_http", "claude", now: @now)

    assert old_view.status == :expired

    assert {:ok, fresh_view} =
             ResultReadback.get_for_client(fresh.id, "mcp_http", "claude", now: @now)

    assert fresh_view.status == :pending
  end

  test "supervised sweeper clears expired rows without client polling" do
    now = DateTime.utc_now()

    assert {:ok, call_result} =
             ResultReadback.create(
               %{
                 surface: "mcp_http",
                 client_id: "claude",
                 action_label: "stale",
                 result: %{message: "stored result"},
                 expires_at: DateTime.add(now, -1, :second)
               },
               now: now
             )

    name = :"result_readback_sweeper_#{System.unique_integer([:positive])}"

    start_supervised!({ResultReadbackSweeper, name: name, interval_ms: 25, schedule?: true})

    assert eventually(fn ->
             updated = Repo.get!(CallResult, call_result.id)
             updated.status == "expired" and updated.result == %{} and updated.error == %{}
           end)
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end
end
