defmodule AllbertAssistWeb.PackReadinessTest do
  use ExUnit.Case, async: false

  alias AllbertAssistWeb.PackReadiness

  defmodule ReadinessStub do
    @key {__MODULE__, :status}

    def put(status), do: :persistent_term.put(@key, status)
    def clear, do: :persistent_term.erase(@key)

    def status(opts \\ []) do
      if Keyword.get(opts, :timeout) == 100,
        do: :persistent_term.get(@key, {:error, :unavailable}),
        else: {:error, :unavailable}
    end
  end

  defmodule BridgeSupervisorStub do
    @key {__MODULE__, :pids}
    @fail_key {__MODULE__, :fail?}

    def reset do
      :persistent_term.put(@key, [])
      :persistent_term.put(@fail_key, false)
    end

    def fail?, do: :persistent_term.get(@fail_key, false)
    def fail, do: :persistent_term.put(@fail_key, true)
    def pids, do: :persistent_term.get(@key, [])

    def open(_epoch, _supervisor) do
      if fail?() do
        {:error, :unavailable}
      else
        pid = spawn(&loop/0)
        :persistent_term.put(@key, pids() ++ [pid])
        {:ok, pid}
      end
    end

    defp loop do
      receive do
        {:"$gen_cast", :close} -> :ok
        _message -> loop()
      end
    end
  end

  test "admits only a monitored ready epoch and rejects its replacement token" do
    barrier =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    digest = String.duplicate("a", 64)

    ReadinessStub.put({:ok, ready_status(barrier, digest)})
    BridgeSupervisorStub.reset()
    on_exit(&ReadinessStub.clear/0)

    observer =
      start_supervised!({
        PackReadiness,
        name: nil, readiness: ReadinessStub, bridge_open_fun: &BridgeSupervisorStub.open/2
      })

    assert_eventually(fn ->
      assert {:ok, epoch} = GenServer.call(observer, :admit)
      assert epoch == %{barrier_pid: barrier, snapshot_digest: digest}
      assert :ok = GenServer.call(observer, {:validate, epoch})

      assert {:error, :stale_epoch} =
               GenServer.call(
                 observer,
                 {:validate, %{epoch | snapshot_digest: String.duplicate("b", 64)}}
               )
    end)

    Process.exit(barrier, :kill)

    assert_eventually(fn ->
      assert {:error, :product_not_ready} = GenServer.call(observer, :admit)
    end)
  end

  test "rechecks readiness for every validation and closes before admitting a replacement epoch" do
    first_barrier =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    second_barrier =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    first_epoch = %{barrier_pid: first_barrier, snapshot_digest: String.duplicate("a", 64)}

    ReadinessStub.put({:ok, ready_status(first_barrier, first_epoch.snapshot_digest)})
    BridgeSupervisorStub.reset()

    on_exit(fn ->
      ReadinessStub.clear()
      Process.exit(first_barrier, :kill)
      Process.exit(second_barrier, :kill)
    end)

    observer =
      start_supervised!({
        PackReadiness,
        name: nil, readiness: ReadinessStub, bridge_open_fun: &BridgeSupervisorStub.open/2
      })

    assert_eventually(fn ->
      assert {:ok, ^first_epoch} = GenServer.call(observer, :admit)
    end)

    [first_bridge] = BridgeSupervisorStub.pids()
    :erlang.suspend_process(first_bridge)

    ReadinessStub.put({:ok, ready_status(second_barrier, String.duplicate("b", 64))})

    assert {:error, :product_not_ready} = GenServer.call(observer, {:validate, first_epoch})
    send(observer, :probe)

    assert {:error, :product_not_ready} = GenServer.call(observer, :admit)
    assert [^first_bridge] = BridgeSupervisorStub.pids()
    assert Process.alive?(first_bridge)

    :erlang.resume_process(first_bridge)
    assert_eventually(fn -> refute Process.alive?(first_bridge) end)

    assert_eventually(fn ->
      assert {:ok, %{barrier_pid: ^second_barrier}} = GenServer.call(observer, :admit)
      assert [^first_bridge, second_bridge] = BridgeSupervisorStub.pids()
      assert first_bridge != second_bridge
    end)
  end

  test "bridge loss and bridge-open failure leave the monitored Pack epoch admitted" do
    barrier =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    epoch = %{barrier_pid: barrier, snapshot_digest: String.duplicate("c", 64)}
    ReadinessStub.put({:ok, ready_status(barrier, epoch.snapshot_digest)})
    BridgeSupervisorStub.reset()

    on_exit(fn ->
      ReadinessStub.clear()
      Process.exit(barrier, :kill)
    end)

    observer =
      start_supervised!({
        PackReadiness,
        name: nil, readiness: ReadinessStub, bridge_open_fun: &BridgeSupervisorStub.open/2
      })

    assert_eventually(fn ->
      assert {:ok, ^epoch} = GenServer.call(observer, :admit)
      assert [first_bridge] = BridgeSupervisorStub.pids()
      Process.exit(first_bridge, :kill)
    end)

    assert_eventually(fn ->
      assert {:ok, ^epoch} = GenServer.call(observer, :admit)
      assert :ok = GenServer.call(observer, {:validate, epoch})
      assert [_first_bridge, second_bridge] = BridgeSupervisorStub.pids()
      assert Process.alive?(second_bridge)
    end)

    BridgeSupervisorStub.fail()
    [_first_bridge, second_bridge] = BridgeSupervisorStub.pids()
    Process.exit(second_bridge, :kill)

    assert_eventually(fn ->
      assert {:ok, ^epoch} = GenServer.call(observer, :admit)
      assert :ok = GenServer.call(observer, {:validate, epoch})
    end)
  end

  test "the production bridge opener completes without re-entering its observer" do
    barrier = spawn(fn -> Process.sleep(:infinity) end)
    epoch = %{barrier_pid: barrier, snapshot_digest: String.duplicate("d", 64)}
    ReadinessStub.put({:ok, ready_status(barrier, epoch.snapshot_digest)})

    on_exit(fn ->
      ReadinessStub.clear()
      Process.exit(barrier, :kill)
    end)

    bridge_supervisor = start_supervised!({AllbertAssistWeb.SignalBridgeSupervisor, name: nil})

    observer =
      start_supervised!({
        PackReadiness,
        name: nil, readiness: ReadinessStub, bridge_supervisor: bridge_supervisor
      })

    assert_eventually(fn ->
      assert {:ok, ^epoch} = GenServer.call(observer, :admit)

      assert %{bridge: {:open, bridge_pid, _bridge_ref, ^epoch}} =
               :sys.get_state(observer)

      assert Process.alive?(bridge_pid)
    end)
  end

  test "an E1 socket admission paused before subscription is rejected when its mount reaches E2" do
    e1_barrier =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    e2_barrier =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    e1 = %{barrier_pid: e1_barrier, snapshot_digest: String.duplicate("1", 64)}
    e2 = %{barrier_pid: e2_barrier, snapshot_digest: String.duplicate("2", 64)}

    ReadinessStub.put({:ok, ready_status(e1.barrier_pid, e1.snapshot_digest)})
    BridgeSupervisorStub.reset()

    on_exit(fn ->
      ReadinessStub.clear()
      Process.exit(e1_barrier, :kill)
      Process.exit(e2_barrier, :kill)
    end)

    observer =
      start_supervised!({
        PackReadiness,
        name: nil, readiness: ReadinessStub, bridge_open_fun: &BridgeSupervisorStub.open/2
      })

    # E1 is the token the custom LiveSocket carries while its connect callback
    # is conceptually paused before Phoenix subscribes the socket ID.
    assert_eventually(fn -> assert {:ok, ^e1} = GenServer.call(observer, :admit) end)

    ReadinessStub.put({:ok, ready_status(e2.barrier_pid, e2.snapshot_digest)})

    # The first E2-era mount validation closes admission and rejects E1; it
    # cannot inherit E2 or continue with the stale carried token.
    assert {:error, :product_not_ready} = GenServer.call(observer, {:validate, e1})

    assert_eventually(fn ->
      assert {:ok, ^e2} = GenServer.call(observer, :admit)
      assert {:error, :stale_epoch} = GenServer.call(observer, {:validate, e1})
    end)
  end

  defp ready_status(barrier_pid, digest) do
    %{
      phase: :ready,
      barrier_pid: barrier_pid,
      snapshot_digest: digest,
      expected_ids: [],
      subscribed_ids: [],
      acked_ids: [],
      diagnostics: []
    }
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
  end
end
