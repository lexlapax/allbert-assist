defmodule AllbertAssist.FirstRun.Enablement.BootWorkerTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.FirstRun.Enablement.BootWorker

  test "start_link crosses the child-init barrier only after reconciliation" do
    caller = self()

    assert {:ok, pid} =
             BootWorker.start_link(
               runner: fn ->
                 send(caller, :reconciled)
                 :done
               end
             )

    assert_receive :reconciled
    refute Process.alive?(pid)
  end
end
