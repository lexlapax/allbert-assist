defmodule AllbertAssist.JidoBacked.SupervisorTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Confirmations.Store.Agent, as: StoreAgent
  alias AllbertAssist.JidoBacked.Supervisor, as: JidoBackedSupervisor

  test "application supervisor hosts child specs from JidoBacked agents" do
    assert pid = Process.whereis(JidoBackedSupervisor)

    children = Supervisor.which_children(pid)
    assert [{StoreAgent, child_pid, :worker, [StoreAgent]}] = children
    assert is_pid(child_pid)
  end
end
