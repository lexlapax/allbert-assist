defmodule AllbertAssist.Objectives.Runs.SchedulerTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Objectives.Runs.Scheduler

  test "enforces independent global/per-fanout limits with FIFO and cross-fanout fairness" do
    name = unique_name()

    start_supervised!(
      {Scheduler,
       name: name,
       max_concurrent_runs_global: 2,
       max_concurrent_runs_per_fanout: 1,
       rehydrate?: false}
    )

    assert :granted = Scheduler.request_slot("a", "a1", self(), name)
    assert :queued = Scheduler.request_slot("a", "a2", self(), name)
    assert :queued = Scheduler.request_slot("a", "a3", self(), name)
    assert :granted = Scheduler.request_slot("b", "b1", self(), name)
    assert :queued = Scheduler.request_slot("b", "b2", self(), name)

    snapshot = Scheduler.snapshot(name)
    assert snapshot.active == %{"a1" => "a", "b1" => "b"}
    assert Enum.map(snapshot.waiting["a"], &elem(&1, 0)) == ["a2", "a3"]

    Scheduler.release("a1", name)
    assert_receive {:run_grant, "a2"}
    refute_receive {:run_grant, "a3"}

    Scheduler.release("b1", name)
    assert_receive {:run_grant, "b2"}

    Scheduler.release("a2", name)
    assert_receive {:run_grant, "a3"}
  end

  test "duplicate requests do not duplicate queue entries" do
    name = unique_name()
    start_supervised!({Scheduler, name: name, max_concurrent_runs_global: 1, rehydrate?: false})

    assert :granted = Scheduler.request_slot("a", "a1", self(), name)
    assert :queued = Scheduler.request_slot("a", "a2", self(), name)
    assert :queued = Scheduler.request_slot("a", "a2", self(), name)

    assert length(Scheduler.snapshot(name).waiting["a"]) == 1
  end

  defp unique_name do
    String.to_atom("scheduler_test_#{System.unique_integer([:positive])}")
  end
end
