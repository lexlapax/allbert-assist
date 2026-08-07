defmodule AllbertAssist.FirstRun.Enablement.BootWorkerTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.FirstRun.Enablement.BootWorker
  alias AllbertAssist.FirstRun.Enablement.Latch
  alias AllbertAssist.Pack.ActivationContext

  defmodule AuthorizingBarrier do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, :ok}

    @impl true
    def handle_call({:validate_activation, _context}, _from, state), do: {:reply, :ok, state}
  end

  defmodule RevokedBarrier do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, :ok}

    @impl true
    def handle_call({:validate_activation, _context}, _from, state),
      do: {:reply, {:error, :stale_activation}, state}
  end

  test "start_link crosses the child-init barrier only after reconciliation" do
    caller = self()

    assert {:ok, pid} =
             BootWorker.start_link(
               allbert_pack_activation: authorizing_context(),
               runner: fn ->
                 send(caller, :reconciled)
                 :done
               end
             )

    assert_receive :reconciled
    refute Process.alive?(pid)
  end

  test "uses the substrate latch to reconcile once across residual effect restarts" do
    caller = self()
    latch = String.to_atom("boot_worker_latch_#{System.unique_integer([:positive])}")
    start_supervised!({Latch, name: latch})

    assert {:ok, first} =
             BootWorker.start_link(
               allbert_pack_activation: authorizing_context(),
               latch: latch,
               runner: fn ->
                 send(caller, :reconciled_once)
                 :done
               end
             )

    assert_receive :reconciled_once
    refute Process.alive?(first)

    assert {:ok, second} =
             BootWorker.start_link(
               allbert_pack_activation: authorizing_context(),
               latch: latch,
               runner: fn -> send(caller, :reconciled_twice) end
             )

    refute_receive :reconciled_twice
    refute Process.alive?(second)
  end

  test "rejects ordinary start without an authorizing carrier before provider or Settings work" do
    caller = self()

    assert_rejected_start(runner: fn -> send(caller, :should_not_run) end)

    refute_receive :should_not_run
  end

  test "passes the exact authorizing carrier to the boot reconciliation root" do
    caller = self()
    context = authorizing_context()

    assert {:ok, pid} =
             BootWorker.start_link(
               allbert_pack_activation: context,
               runner: fn received -> send(caller, {:reconciled_with, received}) end
             )

    assert_receive {:reconciled_with, ^context}
    refute Process.alive?(pid)
  end

  test "rejects a revoked activation before the boot root can probe or reconcile" do
    caller = self()

    assert_rejected_start(
      allbert_pack_activation: revoked_context(),
      runner: fn _context -> send(caller, :should_not_probe) end
    )

    refute_receive :should_not_probe
  end

  defp assert_rejected_start(opts) do
    owner = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        send(owner, {result_ref, BootWorker.start_link(opts)})
      end)

    assert_receive {^result_ref, {:error, :product_not_ready}}
    assert_receive {:DOWN, ^monitor_ref, :process, ^pid, :normal}
  end

  defp authorizing_context do
    barrier =
      start_supervised!(
        Supervisor.child_spec({AuthorizingBarrier, []}, id: {AuthorizingBarrier, make_ref()})
      )

    %ActivationContext{
      schema_version: 1,
      pack_id: "allbert_assist",
      gate_pid: self(),
      barrier_pid: barrier,
      subscription_ref: make_ref(),
      snapshot_digest: String.duplicate("a", 64)
    }
  end

  defp revoked_context do
    barrier = start_supervised!(RevokedBarrier)

    %ActivationContext{
      schema_version: 1,
      pack_id: "allbert_assist",
      gate_pid: self(),
      barrier_pid: barrier,
      subscription_ref: make_ref(),
      snapshot_digest: String.duplicate("a", 64)
    }
  end
end
