defmodule AllbertAssist.HealthTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Health

  defmodule ReadinessStub do
    @key {__MODULE__, :status}

    def put(status), do: :persistent_term.put(@key, status)
    def clear, do: :persistent_term.erase(@key)
    def status(timeout: 100), do: :persistent_term.get(@key, {:error, :unavailable})
  end

  defmodule CoordinatorStub do
    use GenServer

    def start_link(epoch), do: GenServer.start_link(__MODULE__, epoch)

    @impl true
    def init(epoch), do: {:ok, epoch}

    @impl true
    def handle_call(:status, _from, epoch), do: {:reply, %{phase: :ready, epoch: epoch}, epoch}
  end

  test "reports only an ACKed ready epoch as Pack-ready" do
    ReadinessStub.put({:ok, ready_status(["allbert_assist"], ["allbert_assist"])})
    on_exit(&ReadinessStub.clear/0)
    coordinator = start_supervised!({CoordinatorStub, ready_epoch()})

    snapshot = Health.snapshot(readiness: ReadinessStub, coordinator: coordinator)

    assert snapshot.pack == %{
             status: :ready,
             phase: :ready,
             snapshot_digest: String.duplicate("a", 64),
             expected_ids: ["allbert_assist"],
             acked_ids: ["allbert_assist"],
             coordinator: :ready
           }
  end

  test "does not report ready before every required owner has acknowledged" do
    ReadinessStub.put(
      {:ok, ready_status(["allbert_assist", "allbert_kernel"], ["allbert_assist"])}
    )

    on_exit(&ReadinessStub.clear/0)
    coordinator = start_supervised!({CoordinatorStub, ready_epoch()})

    snapshot = Health.snapshot(readiness: ReadinessStub, coordinator: coordinator)

    assert %{status: :unavailable, phase: :ready, coordinator: :ready} = snapshot.pack
  end

  test "does not report ready when the acknowledged epoch has no ready coordinator" do
    ReadinessStub.put({:ok, ready_status(["allbert_assist"], ["allbert_assist"])})
    on_exit(&ReadinessStub.clear/0)

    assert %{status: :unavailable, phase: :ready, coordinator: :unavailable} =
             Health.snapshot(readiness: ReadinessStub, coordinator: :missing_health_coordinator).pack
  end

  test "reports bounded Pack unavailability when readiness is down" do
    ReadinessStub.put({:error, :unavailable})
    on_exit(&ReadinessStub.clear/0)

    assert %{
             status: :unavailable,
             phase: :unavailable,
             snapshot_digest: nil,
             expected_ids: [],
             acked_ids: [],
             coordinator: :unavailable
           } =
             Health.snapshot(readiness: ReadinessStub, coordinator: :missing_health_coordinator).pack
  end

  defp ready_status(expected_ids, acked_ids) do
    %{
      phase: :ready,
      barrier_pid: self(),
      snapshot_digest: String.duplicate("a", 64),
      expected_ids: expected_ids,
      subscribed_ids: expected_ids,
      acked_ids: acked_ids,
      diagnostics: []
    }
  end

  defp ready_epoch, do: %{barrier_pid: self(), snapshot_digest: String.duplicate("a", 64)}
end
