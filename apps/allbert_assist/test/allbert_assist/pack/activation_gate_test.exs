defmodule AllbertAssist.Pack.ActivationGateTest do
  use ExUnit.Case, async: false

  @moduletag :global_process_serial

  alias AllbertAssist.Pack.ActivationGate

  defmodule ReadinessStub do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    def subscribe(pack_id, opts),
      do: GenServer.call(Keyword.fetch!(opts, :server), {:subscribe, pack_id, self()})

    def ack(ref, digest, opts),
      do: GenServer.call(Keyword.fetch!(opts, :server), {:ack, ref, digest, self()})

    def nack(ref, digest, reason, opts),
      do: GenServer.call(Keyword.fetch!(opts, :server), {:nack, ref, digest, reason})

    def activate(digest, server), do: GenServer.call(server, {:activate, digest})

    @impl true
    def init(opts), do: {:ok, %{notify: Keyword.fetch!(opts, :notify), subscriber: nil, ref: nil}}

    @impl true
    def handle_call({:subscribe, "allbert_assist", subscriber}, _from, state) do
      ref = make_ref()
      send(state.notify, {:activation_subscribed, self(), ref})

      {:reply, {:ok, %{barrier_pid: self(), subscription_ref: ref, phase: :collecting}},
       %{state | subscriber: subscriber, ref: ref}}
    end

    def handle_call({:validate_activation, _context}, _from, state), do: {:reply, :ok, state}

    def handle_call({:activate, digest}, _from, %{subscriber: subscriber, ref: ref} = state) do
      send(subscriber, {:allbert_pack_activate, self(), ref, digest})
      {:reply, :ok, state}
    end

    def handle_call(
          {:ack, ref, digest, subscriber},
          _from,
          %{ref: ref, subscriber: subscriber} = state
        ) do
      send(state.notify, {:activation_acked, ref, digest})
      {:reply, :ok, state}
    end

    def handle_call({:nack, _ref, _digest, reason}, _from, state) do
      send(state.notify, {:activation_nacked, reason})
      {:reply, :ok, state}
    end
  end

  defmodule Probe do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      send(Keyword.fetch!(opts, :notify), :residual_effect_started)
      {:ok, %{}}
    end
  end

  defmodule GracefulEffectSupervisor do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      send(Keyword.fetch!(opts, :notify), {:effect_started, self()})
      Process.flag(:trap_exit, true)
      {:ok, %{notify: Keyword.fetch!(opts, :notify)}}
    end

    @impl true
    def handle_info({:EXIT, _from, :shutdown}, state) do
      send(state.notify, {:effect_shutdown_requested, self()})
      Process.send_after(self(), :finish_shutdown, 75)
      {:noreply, state}
    end

    def handle_info(:finish_shutdown, state) do
      send(state.notify, {:effect_stopped, self()})
      {:stop, :normal, state}
    end
  end

  defmodule BlockedStartEffectSupervisor do
    def start_link(opts) do
      notify = Keyword.fetch!(opts, :notify)
      send(notify, {:effect_start_blocked, self()})

      receive do
        :finish_effect_start -> GracefulEffectSupervisor.start_link(opts)
      end
    end
  end

  test "starts the complete residual subtree and ACKs only after its boot worker exits normally" do
    caller = self()
    barrier = unique_name(:activation_barrier)
    gate = unique_name(:activation_gate)
    app_registry = unique_name(:activation_app_registry)
    plugin_registry = unique_name(:activation_plugin_registry)
    app_dynamic_supervisor = unique_name(:activation_app_dynamic_supervisor)
    plugin_child_supervisor = unique_name(:activation_plugin_child_supervisor)

    start_supervised!({ReadinessStub, name: barrier, notify: self()})
    start_supervised!({AllbertAssist.App.Registry, name: app_registry, enabled?: false})
    start_supervised!({AllbertAssist.Plugin.Registry, name: plugin_registry, enabled?: false})

    start_supervised!(
      {ActivationGate,
       name: gate,
       readiness: ReadinessStub,
       readiness_opts: [server: barrier],
       effect_supervisor_opts: [
         app_registry: app_registry,
         plugin_registry: plugin_registry,
         app_dynamic_supervisor: app_dynamic_supervisor,
         plugin_child_supervisor: plugin_child_supervisor,
         effect_children: [
           {AllbertAssist.FirstRun.Enablement.BootWorker,
            runner: fn activation -> send(caller, {:first_run_reconciled, activation}) end},
           {Probe, notify: self()}
         ]
       ]}
    )

    assert_eventually(fn ->
      assert %{barrier_pid: barrier_pid} = ActivationGate.status(gate)
      assert is_pid(barrier_pid)
    end)

    assert :ok = ReadinessStub.activate(valid_digest(), barrier)

    assert_receive :residual_effect_started
    assert_receive {:first_run_reconciled, %AllbertAssist.Pack.ActivationContext{}}
    assert_receive {:activation_acked, _subscription_ref, digest}
    assert %{phase: :ready, effect_supervisor: effect_pid} = ActivationGate.status(gate)
    assert is_pid(effect_pid)
    assert digest == valid_digest()
  end

  test "waits for the retired effect supervisor to be DOWN before subscribing to a replacement barrier" do
    barrier = unique_name(:replacement_barrier)
    gate = unique_name(:replacement_gate)

    start_supervised!(
      Supervisor.child_spec({ReadinessStub, name: barrier, notify: self()}, restart: :temporary)
    )

    start_supervised!(
      {ActivationGate,
       name: gate,
       readiness: ReadinessStub,
       readiness_opts: [server: barrier],
       effect_supervisor: GracefulEffectSupervisor,
       effect_supervisor_opts: [notify: self()]}
    )

    assert_receive {:activation_subscribed, first_barrier, _first_ref}
    assert :ok = ReadinessStub.activate(valid_digest(), barrier)
    assert_receive {:effect_started, first_effect}
    assert_receive {:activation_acked, _subscription_ref, digest}
    assert digest == valid_digest()

    Process.exit(first_barrier, :kill)

    assert_receive {:effect_shutdown_requested, ^first_effect}

    assert %{phase: :collecting, barrier_pid: nil, effect_supervisor: nil} =
             ActivationGate.status(gate)

    start_supervised!(
      Supervisor.child_spec({ReadinessStub, name: barrier, notify: self()}, restart: :temporary)
    )

    refute_receive {:activation_subscribed, _replacement_barrier, _replacement_ref}, 30
    assert_receive {:effect_stopped, ^first_effect}
    refute Process.alive?(first_effect)
    assert_receive {:activation_subscribed, replacement_barrier, _replacement_ref}, 500
    refute replacement_barrier == first_barrier

    assert :ok = ReadinessStub.activate(valid_digest(), barrier)
    assert_receive {:effect_started, replacement_effect}
    assert_receive {:activation_acked, _subscription_ref, digest}
    assert digest == valid_digest()
    refute replacement_effect == first_effect
  end

  test "barrier loss during activation retires the started subtree and worker before resubscribe" do
    barrier = unique_name(:authorizing_barrier)
    gate = unique_name(:authorizing_gate)
    caller = self()

    start_supervised!(
      Supervisor.child_spec({ReadinessStub, name: barrier, notify: self()}, restart: :temporary)
    )

    after_result = fn {:ok, effect_pid} ->
      send(caller, {:activation_result_sent, self(), effect_pid})

      receive do
        :release_activation_worker -> :ok
      end
    end

    start_supervised!(
      {ActivationGate,
       name: gate,
       readiness: ReadinessStub,
       readiness_opts: [server: barrier],
       effect_supervisor: GracefulEffectSupervisor,
       effect_supervisor_opts: [notify: self()],
       activation_worker_after_result: after_result}
    )

    assert_receive {:activation_subscribed, first_barrier, _first_ref}
    assert :ok = ReadinessStub.activate(valid_digest(), barrier)
    assert_receive {:effect_started, first_effect}
    assert_receive {:activation_result_sent, worker, ^first_effect}

    Process.exit(first_barrier, :kill)
    assert_receive {:effect_shutdown_requested, ^first_effect}

    start_supervised!(
      Supervisor.child_spec({ReadinessStub, name: barrier, notify: self()}, restart: :temporary)
    )

    assert_receive {:effect_stopped, ^first_effect}
    refute Process.alive?(first_effect)
    refute_receive {:activation_subscribed, _replacement_barrier, _replacement_ref}, 30

    send(worker, :release_activation_worker)
    assert_receive {:activation_subscribed, replacement_barrier, _replacement_ref}, 500
    refute replacement_barrier == first_barrier
  end

  test "barrier loss while the activation worker is starting waits for its subtree result" do
    barrier = unique_name(:starting_barrier)
    gate = unique_name(:starting_gate)

    start_supervised!(
      Supervisor.child_spec({ReadinessStub, name: barrier, notify: self()}, restart: :temporary)
    )

    start_supervised!(
      {ActivationGate,
       name: gate,
       readiness: ReadinessStub,
       readiness_opts: [server: barrier],
       effect_supervisor: BlockedStartEffectSupervisor,
       effect_supervisor_opts: [notify: self()]}
    )

    assert_receive {:activation_subscribed, first_barrier, _first_ref}
    assert :ok = ReadinessStub.activate(valid_digest(), barrier)
    assert_receive {:effect_start_blocked, worker}

    Process.exit(first_barrier, :kill)
    assert_eventually(fn -> refute Process.alive?(first_barrier) end)

    start_supervised!(
      {ReadinessStub, name: barrier, notify: self()},
      id: unique_name(:replacement_readiness)
    )

    refute_receive {:activation_subscribed, _replacement_barrier, _replacement_ref}, 30

    send(worker, :finish_effect_start)
    assert_receive {:effect_started, first_effect}
    assert_receive {:effect_shutdown_requested, ^first_effect}
    assert_receive {:effect_stopped, ^first_effect}
    refute Process.alive?(first_effect)
    assert_receive {:activation_subscribed, replacement_barrier, _replacement_ref}, 500
    refute replacement_barrier == first_barrier
  end

  defp valid_digest, do: String.duplicate("a", 64)

  defp unique_name(prefix), do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")

  defp assert_eventually(fun, attempts \\ 30)
  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    _error ->
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
  end
end
