defmodule AllbertAssist.PublicProtocol.AcpFanoutTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  @source Path.expand("../../../lib/allbert_assist/public_protocol/acp/server.ex", __DIR__)

  test "stdio owner keeps reading while prompt workers await and cancel through a registered action" do
    source = File.read!(@source)

    assert source =~ "Task.Supervisor.async_nolink(AllbertAssist.TaskSupervisor"
    assert source =~ "Runtime.await_fanout"
    assert source =~ ~s("session/cancel")
    assert source =~ "Runner.run("
    assert source =~ ~s("cancel_objective_run")
    assert source =~ "worker_state.report_deliveries"
    assert source =~ "acknowledge_report_deliveries("
    refute source =~ "acknowledge_session_reports("
  end
end
