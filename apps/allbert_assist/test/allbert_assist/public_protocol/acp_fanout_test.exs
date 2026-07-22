defmodule AllbertAssist.PublicProtocol.AcpFanoutTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  @source Path.expand("../../../lib/allbert_assist/public_protocol/acp/server.ex", __DIR__)

  test "stdio owner keeps reading while prompt workers await and cancel through a registered action" do
    source = File.read!(@source)

    assert source =~ "Task.Supervisor.async_nolink(AllbertAssist.TaskSupervisor"
    assert source =~ "Runtime.await_fanout"
    assert source =~ ~s("session/cancel")
    assert source =~ ~s(Runner.run(
        "cancel_objective")
  end
end
