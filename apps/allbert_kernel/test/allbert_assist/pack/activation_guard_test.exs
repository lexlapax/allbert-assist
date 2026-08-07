defmodule AllbertAssist.Pack.ActivationGuardTest do
  use ExUnit.Case, async: false

  @moduletag :global_process_serial

  alias AllbertAssist.Pack.{ActivationGuard, EffectGuard}
  alias AllbertAssist.Pack.ActivationContext

  defmodule ReadyBarrier do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, :ok}

    @impl true
    def handle_call(:status, _from, state) do
      {:reply,
       {:ok,
        %{
          phase: :ready,
          barrier_pid: self(),
          snapshot_digest: String.duplicate("a", 64),
          expected_ids: [],
          subscribed_ids: [],
          acked_ids: [],
          diagnostics: []
        }}, state}
    end

    def handle_call({:validate_activation, _context}, _from, state), do: {:reply, :ok, state}
  end

  defmodule BlockingBarrier do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_call(message, from, owner) do
      send(owner, {:guard_call_blocked, self(), message, from})

      receive do
        :never -> {:reply, :unexpected, owner}
      end
    end
  end

  test "both public guards fail closed when no product barrier is ready" do
    assert {:error, :product_not_ready} = EffectGuard.admit_ready(server: :m1a3_no_readiness)

    assert {:error, :product_not_ready} =
             EffectGuard.validate(
               %{barrier_pid: self(), snapshot_digest: String.duplicate("a", 64)},
               server: :m1a3_no_readiness
             )

    assert {:error, :product_not_ready} =
             ActivationGuard.validate([allbert_pack_activation: %{}],
               server: :m1a3_no_readiness
             )
  end

  test "effect admission carries one exact epoch and activation validation targets its barrier" do
    barrier = start_supervised!(ReadyBarrier)

    assert {:ok, epoch} = EffectGuard.admit_ready(server: barrier)
    assert :ok = EffectGuard.validate(epoch, server: barrier)

    assert {:error, :stale_epoch} =
             EffectGuard.validate(%{epoch | snapshot_digest: String.duplicate("b", 64)},
               server: barrier
             )

    context = %ActivationContext{
      schema_version: 1,
      pack_id: "allbert_assist",
      gate_pid: self(),
      barrier_pid: barrier,
      subscription_ref: make_ref(),
      snapshot_digest: String.duplicate("a", 64)
    }

    assert {:error, :product_not_ready} = ActivationGuard.validate(context)

    assert :ok = ActivationGuard.validate(allbert_pack_activation: context)

    assert {:error, :product_not_ready} =
             ActivationGuard.validate([allbert_pack_activation: context],
               server: :m1a3_wrong_activation_barrier
             )
  end

  test "all guards fail closed when readiness dies during their calls" do
    epoch = %{barrier_pid: self(), snapshot_digest: String.duplicate("a", 64)}

    assert_kill_during_call(
      fn server -> EffectGuard.admit_ready(server: server) end,
      {:error, :product_not_ready}
    )

    assert_kill_during_call(
      fn server -> EffectGuard.validate(epoch, server: server) end,
      {:error, :product_not_ready}
    )

    assert_kill_during_call(
      fn server ->
        activation_context = %ActivationContext{
          schema_version: 1,
          pack_id: "allbert_assist",
          gate_pid: self(),
          barrier_pid: server,
          subscription_ref: make_ref(),
          snapshot_digest: String.duplicate("a", 64)
        }

        ActivationGuard.validate([allbert_pack_activation: activation_context], server: server)
      end,
      {:error, :product_not_ready}
    )
  end

  defp assert_kill_during_call(call, expected) do
    {:ok, barrier} = BlockingBarrier.start_link(self())
    task = Task.async(fn -> call.(barrier) end)

    assert_receive {:guard_call_blocked, ^barrier, _message, _from}
    Process.unlink(barrier)
    Process.exit(barrier, :kill)

    assert Task.await(task) == expected
  end
end
