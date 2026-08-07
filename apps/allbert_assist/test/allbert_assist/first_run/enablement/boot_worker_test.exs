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

    assert {:error, :product_not_ready} =
             BootWorker.start_link(runner: fn -> send(caller, :should_not_run) end)

    refute_receive :should_not_run
  end

  defp authorizing_context do
    barrier = start_supervised!(AuthorizingBarrier)

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
