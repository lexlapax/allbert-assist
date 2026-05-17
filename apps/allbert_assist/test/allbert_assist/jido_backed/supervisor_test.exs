defmodule AllbertAssist.JidoBacked.SupervisorTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Confirmations.Store.Agent, as: StoreAgent
  alias AllbertAssist.JidoBacked.Supervisor, as: JidoBackedSupervisor

  test "application supervisor hosts child specs from JidoBacked agents" do
    assert pid = Process.whereis(JidoBackedSupervisor)

    children = Supervisor.which_children(pid)
    assert {StoreAgent, store_pid, :worker, [StoreAgent]} = List.keyfind(children, StoreAgent, 0)

    assert {AllbertAssist.Jobs.Scheduler.Agent, scheduler_pid, :worker,
            [AllbertAssist.Jobs.Scheduler.Agent]} =
             List.keyfind(children, AllbertAssist.Jobs.Scheduler.Agent, 0)

    assert is_pid(store_pid)
    assert is_pid(scheduler_pid)
  end
end
