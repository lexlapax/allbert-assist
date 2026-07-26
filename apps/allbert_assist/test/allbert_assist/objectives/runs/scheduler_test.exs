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

  test "an unavailable durable recovery check cannot restart the scheduler" do
    name = unique_name()
    scheduler = start_supervised!({Scheduler, name: name, rehydrate?: false})
    scheduler_ref = Process.monitor(scheduler)

    coordinator = spawn(fn -> receive do: (:stop -> :ok) end)
    Scheduler.track_coordinator("missing-parent", coordinator, name)
    _snapshot = Scheduler.snapshot(name)

    Process.exit(coordinator, :kill)

    refute_receive {:DOWN, ^scheduler_ref, :process, ^scheduler, _reason}, 200
    assert Process.alive?(scheduler)
    assert %{active: %{}, waiting: %{}, rotation: []} = Scheduler.snapshot(name)
  end

  test "unavailable durable state at startup cannot restart the scheduler" do
    name = unique_name()
    scheduler = start_supervised!({Scheduler, name: name})
    scheduler_ref = Process.monitor(scheduler)

    refute_receive {:DOWN, ^scheduler_ref, :process, ^scheduler, _reason}, 200
    assert Process.alive?(scheduler)
    assert %{active: %{}, waiting: %{}, rotation: []} = Scheduler.snapshot(name)
  end

  test "transient rehydration failure retries before installing one live-run monitor" do
    name = unique_name()
    worker = start_registry_fixture({:run, "rehydrated-child"})
    _coordinator = start_registry_fixture({:fanout, "rehydrated-parent"})
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    rehydration_loader = fn ->
      attempt = Agent.get_and_update(attempts, fn count -> {count, count + 1} end)

      case attempt do
        0 ->
          raise %DBConnection.ConnectionError{message: "injected snapshot failure"}

        1 ->
          exit({:shutdown, %DBConnection.ConnectionError{message: "injected snapshot exit"}})

        3 ->
          exit(:injected_programming_exit)

        _attempt ->
          [{%{id: "rehydrated-parent"}, [%{id: "rehydrated-child"}]}]
      end
    end

    scheduler =
      start_supervised!(
        {Scheduler,
         name: name,
         max_concurrent_runs_global: 1,
         max_concurrent_runs_per_fanout: 1,
         rehydration_loader: rehydration_loader}
      )

    eventually(fn ->
      Scheduler.snapshot(name).active == %{"rehydrated-child" => "rehydrated-parent"}
    end)

    assert Agent.get(attempts, & &1) == 3
    assert {:monitors, monitors} = Process.info(scheduler, :monitors)
    assert Enum.count(monitors, &(&1 == {:process, worker})) == 1

    scheduler_ref = Process.monitor(scheduler)
    send(scheduler, :retry_rehydrate)

    assert_receive {:DOWN, ^scheduler_ref, :process, ^scheduler, :injected_programming_exit},
                   1_000
  end

  defp unique_name do
    String.to_atom("scheduler_test_#{System.unique_integer([:positive])}")
  end

  defp start_registry_fixture(key) do
    owner = self()

    pid =
      spawn(fn ->
        result = Registry.register(AllbertAssist.Objectives.Runs.Registry, key, nil)
        send(owner, {:registry_fixture_started, self(), result})
        registry_fixture_loop()
      end)

    assert_receive {:registry_fixture_started, ^pid, {:ok, _owner}}, 1_000

    on_exit(fn ->
      if Process.alive?(pid), do: send(pid, :stop)
    end)

    pid
  end

  defp registry_fixture_loop do
    receive do
      :stop -> :ok
      _message -> registry_fixture_loop()
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
