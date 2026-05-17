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

    assert {AllbertAssist.Objectives.Engine.Agent, engine_pid, :worker,
            [AllbertAssist.Objectives.Engine.Agent]} =
             List.keyfind(children, AllbertAssist.Objectives.Engine.Agent, 0)

    assert is_pid(store_pid)
    assert is_pid(scheduler_pid)
    assert is_pid(engine_pid)
  end

  test "supervisor can append later JidoBacked children without replacing v0.23 agents" do
    name = :"jido_backed_supervisor_#{System.unique_integer([:positive])}"
    store_name = :"jido_backed_store_#{System.unique_integer([:positive])}"
    scheduler_name = :"jido_backed_scheduler_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {JidoBackedSupervisor,
         name: name,
         confirmations: [name: store_name, id: Atom.to_string(store_name)],
         scheduler: [
           name: scheduler_name,
           id: Atom.to_string(scheduler_name),
           enabled?: false,
           poll_on_start?: false,
           cleanup_on_start?: false
         ],
         extra_children: [
           %{
             id: :future_objectives_engine_placeholder,
             start: {Agent, :start_link, [fn -> :future_jido_backed_child end]}
           }
         ]}
      )

    children = Supervisor.which_children(pid)

    assert {StoreAgent, store_pid, :worker, [StoreAgent]} = List.keyfind(children, StoreAgent, 0)

    assert {AllbertAssist.Jobs.Scheduler.Agent, scheduler_pid, :worker,
            [AllbertAssist.Jobs.Scheduler.Agent]} =
             List.keyfind(children, AllbertAssist.Jobs.Scheduler.Agent, 0)

    assert {:future_objectives_engine_placeholder, future_pid, :worker, [Agent]} =
             List.keyfind(children, :future_objectives_engine_placeholder, 0)

    assert is_pid(store_pid)
    assert is_pid(scheduler_pid)
    assert is_pid(future_pid)
  end
end
