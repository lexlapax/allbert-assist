defmodule AllbertAssist.Pack.ReadinessTest do
  use ExUnit.Case, async: false

  @moduletag :global_process_serial

  alias AllbertAssist.Pack.{Readiness, Supervisor}
  alias AllbertAssist.Pack.{Compatibility, Contribution, Descriptor, Order, Owner}
  alias AllbertAssist.Pack.Registry
  alias AllbertAssist.Pack.Registry.Candidate

  defmodule MetadataSource do
    use GenServer

    def start_link(barrier), do: GenServer.start_link(__MODULE__, barrier)

    @impl true
    def init(barrier), do: {:ok, %{barrier: barrier, generation: 7, subscription_ref: make_ref()}}

    @impl true
    def handle_call(:bind, _from, state) do
      result =
        Readiness.bind_metadata(
          state.barrier,
          self(),
          state.generation,
          state.subscription_ref
        )

      {:reply, {result, {self(), state.generation, state.subscription_ref}}, state}
    end
  end

  test "a private barrier starts collecting and admits one tentative subscriber" do
    {:ok, barrier} = Readiness.start_link(name: nil, registry: self(), coordinator: self())
    on_exit(fn -> if Process.alive?(barrier), do: GenServer.stop(barrier) end)

    assert {:ok, %{barrier_pid: ^barrier, subscription_ref: subscription_ref, phase: :collecting}} =
             Readiness.subscribe("allbert_assist", server: barrier)

    assert is_reference(subscription_ref)

    assert {:ok,
            %{
              phase: :collecting,
              barrier_pid: ^barrier,
              snapshot_digest: nil,
              expected_ids: [],
              subscribed_ids: ["allbert_assist"],
              acked_ids: [],
              diagnostics: []
            }} = Readiness.status(server: barrier)
  end

  test "an unavailable barrier is fail closed" do
    assert {:error, :unavailable} = Readiness.status(server: :m1a3_no_readiness)

    assert {:error, :unavailable} =
             Readiness.subscribe("allbert_assist", server: :m1a3_no_readiness)
  end

  test "duplicate subscriber ownership is rejected while exact resubscribe is idempotent" do
    {:ok, barrier} = Readiness.start_link(name: nil, registry: self(), coordinator: self())
    on_exit(fn -> if Process.alive?(barrier), do: GenServer.stop(barrier) end)

    assert {:ok, %{subscription_ref: subscription_ref}} =
             Readiness.subscribe("allbert_assist", server: barrier)

    assert {:ok, %{subscription_ref: ^subscription_ref, phase: :collecting}} =
             Readiness.subscribe("allbert_assist", server: barrier)

    parent = self()

    other =
      spawn(fn ->
        send(parent, {:duplicate_result, Readiness.subscribe("allbert_assist", server: barrier)})
      end)

    assert_receive {:duplicate_result,
                    {:error, %{code: :duplicate_subscriber, pack_id: "allbert_assist"}}}
    refute Process.alive?(other)
  end

  @tag capture_log: true
  test "one fixed open deadline distinguishes a missing subscriber from activation timeout" do
    Process.flag(:trap_exit, true)
    {:ok, registry} = Registry.start_link(name: nil, coordinator: self())
    on_exit(fn -> if Process.alive?(registry), do: GenServer.stop(registry) end)
    assert {:ok, snapshot} = Registry.finalize(candidate_with_effectful_pack(), server: registry)

    parent = self()

    coordinator =
      spawn(fn ->
        receive do
          {:open, barrier} ->
            send(
              parent,
              {:open_result,
               Readiness.open(snapshot.behavior_digest, ["allbert_assist"], server: barrier)}
            )

            receive do: (:stop -> :ok)
        end
      end)

    {:ok, barrier} = Readiness.start_link(name: nil, registry: registry, coordinator: coordinator)
    send(coordinator, {:open, barrier})

    assert eventually(fn ->
             match?({:ok, %{phase: :authorizing}}, Readiness.status(server: barrier))
           end)

    send(barrier, :open_timeout)

    assert_receive {:open_result,
                    {:error,
                     %{code: :subscriber_timeout, expected_ids: ["allbert_assist"], actual_ids: []}}}

    assert_receive {:EXIT, ^barrier, :shutdown}
    assert {:error, :unavailable} = Readiness.status(server: barrier)
    send(coordinator, :stop)
  end

  @tag capture_log: true
  test "NACK reports a redacted activation failure and tears down the epoch" do
    Process.flag(:trap_exit, true)
    {:ok, registry} = Registry.start_link(name: nil, coordinator: self())
    on_exit(fn -> if Process.alive?(registry), do: GenServer.stop(registry) end)
    assert {:ok, snapshot} = Registry.finalize(candidate_with_effectful_pack(), server: registry)

    parent = self()

    coordinator =
      spawn(fn ->
        receive do
          {:open, barrier} ->
            send(
              parent,
              {:open_result,
               Readiness.open(snapshot.behavior_digest, ["allbert_assist"], server: barrier)}
            )
        end
      end)

    {:ok, barrier} = Readiness.start_link(name: nil, registry: registry, coordinator: coordinator)

    subscriber =
      spawn(fn ->
        {:ok, %{subscription_ref: subscription_ref}} =
          Readiness.subscribe("allbert_assist", server: barrier)

        send(parent, :subscriber_ready)

        receive do
          {:allbert_pack_activate, ^barrier, ^subscription_ref, digest} ->
            send(
              parent,
              {:nack_result,
               Readiness.nack(subscription_ref, digest, {:raw, self()}, server: barrier)}
            )
        end
      end)

    assert_receive :subscriber_ready
    send(coordinator, {:open, barrier})

    assert_receive {:open_result,
                    {:error,
                     %{code: :activation_nack, detail: %{}, pack_id: "allbert_assist"}}}
    assert_receive {:nack_result, :ok}
    assert_receive {:EXIT, ^barrier, :shutdown}
    assert eventually(fn -> not Process.alive?(subscriber) end)
  end

  test "ACK requires the exact subscriber caller and closes activation context after success" do
    {:ok, registry} = Registry.start_link(name: nil, coordinator: self())
    on_exit(fn -> if Process.alive?(registry), do: GenServer.stop(registry) end)
    assert {:ok, snapshot} = Registry.finalize(candidate_with_effectful_pack(), server: registry)

    parent = self()

    coordinator =
      spawn(fn ->
        receive do
          {:open, barrier} ->
            send(
              parent,
              {:open_result,
               Readiness.open(snapshot.behavior_digest, ["allbert_assist"], server: barrier)}
            )

            receive do: (:stop -> :ok)
        end
      end)

    {:ok, barrier} = Readiness.start_link(name: nil, registry: registry, coordinator: coordinator)

    subscriber =
      spawn(fn ->
        {:ok, %{subscription_ref: subscription_ref}} =
          Readiness.subscribe("allbert_assist", server: barrier)

        send(parent, {:subscription_ref, subscription_ref})

        receive do
          {:allbert_pack_activate, ^barrier, ^subscription_ref, digest} ->
            send(parent, {:activation, subscription_ref, digest})

            receive do
              :ack ->
                send(
                  parent,
                  {:ack_result, Readiness.ack(subscription_ref, digest, server: barrier)}
                )

                receive do: (:stop -> :ok)
            end
        end
      end)

    assert_receive {:subscription_ref, subscription_ref}
    send(coordinator, {:open, barrier})
    assert_receive {:activation, ^subscription_ref, digest}

    assert {:error, %{code: :stale_epoch}} =
             Readiness.ack(subscription_ref, digest, server: barrier)

    send(subscriber, :ack)
    assert_receive {:ack_result, :ok}
    assert_receive {:open_result, {:ok, %{phase: :ready}}}

    context = %AllbertAssist.Pack.ActivationContext{
      schema_version: 1,
      pack_id: "allbert_assist",
      gate_pid: subscriber,
      barrier_pid: barrier,
      subscription_ref: subscription_ref,
      snapshot_digest: digest
    }

    assert {:error, :product_not_ready} = Readiness.validate_activation(context)
    assert :ok = Readiness.ack(subscription_ref, digest, server: barrier, subscriber: subscriber)
    send(subscriber, :stop)
    send(coordinator, :stop)
  end

  @tag capture_log: true
  test "coordinator loss withdraws an already-ready empty epoch" do
    Process.flag(:trap_exit, true)
    {:ok, registry} = Registry.start_link(name: nil, coordinator: self())
    on_exit(fn -> if Process.alive?(registry), do: GenServer.stop(registry) end)
    assert {:ok, snapshot} = Registry.finalize(empty_candidate(), server: registry)

    parent = self()

    coordinator =
      spawn(fn ->
        receive do
          {:open, barrier} ->
            send(parent, {:open_result, Readiness.open(snapshot.behavior_digest, [], server: barrier)})
            receive do: (:stop -> :ok)
        end
      end)

    {:ok, barrier} = Readiness.start_link(name: nil, registry: registry, coordinator: coordinator)
    send(coordinator, {:open, barrier})
    assert_receive {:open_result, {:ok, %{phase: :ready}}}

    Process.exit(coordinator, :kill)

    assert_receive {:EXIT, ^barrier, :shutdown}
    assert {:error, :unavailable} = Readiness.status(server: barrier)
  end

  test "a finalized exact subscriber receives one activation and acknowledges a ready epoch" do
    Process.flag(:trap_exit, true)

    {:ok, registry} = Registry.start_link(name: nil, coordinator: self())
    on_exit(fn -> if Process.alive?(registry), do: GenServer.stop(registry) end)

    assert {:ok, snapshot} = Registry.finalize(candidate_with_effectful_pack(), server: registry)

    {:ok, barrier} = Readiness.start_link(name: nil, registry: registry, coordinator: self())
    on_exit(fn -> if Process.alive?(barrier), do: GenServer.stop(barrier) end)

    parent = self()

    subscriber =
      spawn(fn ->
        case Readiness.subscribe("allbert_assist", server: barrier) do
          {:ok, %{subscription_ref: subscription_ref}} ->
            receive do
              {:allbert_pack_activate, ^barrier, ^subscription_ref, digest} ->
                send(parent, {:activation, self(), subscription_ref, digest})

                send(
                  parent,
                  {:ack_result, Readiness.ack(subscription_ref, digest, server: barrier)}
                )

                receive do: (:stop -> :ok)
            end

          other ->
            send(parent, {:subscriber_error, other})
        end
      end)

    assert {:ok, %{barrier_pid: ^barrier, snapshot_digest: digest, phase: :ready}} =
             Readiness.open(snapshot.behavior_digest, ["allbert_assist"], server: barrier)

    assert digest == snapshot.behavior_digest
    refute_receive {:subscriber_error, _result}
    assert_receive {:activation, ^subscriber, _subscription_ref, ^digest}
    assert_receive {:ack_result, :ok}

    assert {:ok, %{phase: :ready, acked_ids: ["allbert_assist"]}} =
             Readiness.status(server: barrier)

    refute_receive {:EXIT, ^barrier, _reason}
    send(subscriber, :stop)
  end

  test "open requires exact finalized effectful ids rather than any contribution subset" do
    {:ok, registry} = Registry.start_link(name: nil, coordinator: self())
    on_exit(fn -> if Process.alive?(registry), do: GenServer.stop(registry) end)

    assert {:ok, snapshot} =
             Registry.finalize(candidate_with_effectful_pack(),
               server: registry,
               effectful_ids: []
             )

    assert {:ok, []} = Registry.effectful_ids(server: registry)

    {:ok, barrier} = Readiness.start_link(name: nil, registry: registry, coordinator: self())
    on_exit(fn -> if Process.alive?(barrier), do: GenServer.stop(barrier) end)

    assert {:error, %{code: :expected_ids_mismatch}} =
             Readiness.open(snapshot.behavior_digest, ["allbert_assist"], server: barrier)

    assert {:ok, %{phase: :ready}} =
             Readiness.open(snapshot.behavior_digest, [], server: barrier)
  end

  test "open fails closed while Registry is collecting and sends no activation" do
    {:ok, registry} = Registry.start_link(name: nil, coordinator: self())
    on_exit(fn -> if Process.alive?(registry), do: GenServer.stop(registry) end)

    {:ok, barrier} = Readiness.start_link(name: nil, registry: registry, coordinator: self())
    on_exit(fn -> if Process.alive?(barrier), do: GenServer.stop(barrier) end)

    assert {:ok, %{subscription_ref: subscription_ref}} =
             Readiness.subscribe("allbert_assist", server: barrier)

    assert {:error, %{code: :registry_collecting, phase: :collecting}} =
             Readiness.open(String.duplicate("a", 64), [], server: barrier)

    refute_receive {:allbert_pack_activate, ^barrier, ^subscription_ref, _digest}
  end

  @tag capture_log: true
  test "Pack supervision restarts Registry and Readiness as one fresh collecting epoch" do
    registry_name = :m1a3_supervised_registry
    readiness_name = :m1a3_supervised_readiness

    supervisor =
      start_supervised!(
        {Supervisor,
         name: :m1a3_pack_supervisor,
         registry: registry_name,
         readiness: readiness_name,
         coordinator: self()}
      )

    assert is_pid(supervisor)
    first_registry = Process.whereis(registry_name)
    first_readiness = Process.whereis(readiness_name)
    assert is_pid(first_registry)
    assert is_pid(first_readiness)

    Process.exit(first_registry, :shutdown)

    assert eventually(fn ->
             replacement_registry = Process.whereis(registry_name)
             replacement_readiness = Process.whereis(readiness_name)

             is_pid(replacement_registry) and is_pid(replacement_readiness) and
               replacement_registry != first_registry and replacement_readiness != first_readiness
           end)

    assert {:ok, %{phase: :collecting, snapshot_digest: nil}} =
             Readiness.status(server: readiness_name)
  end

  @tag capture_log: true
  test "a bound metadata source is part of the epoch and its loss tears readiness down" do
    Process.flag(:trap_exit, true)

    {:ok, registry} = Registry.start_link(name: nil, coordinator: self())
    on_exit(fn -> if Process.alive?(registry), do: GenServer.stop(registry) end)
    assert {:ok, snapshot} = Registry.finalize(empty_candidate(), server: registry)

    {:ok, barrier} = Readiness.start_link(name: nil, registry: registry, coordinator: self())
    on_exit(fn -> if Process.alive?(barrier), do: GenServer.stop(barrier) end)

    source = start_supervised!({MetadataSource, barrier})
    assert {:ok, metadata_source} = GenServer.call(source, :bind)

    assert {:ok, %{phase: :ready}} =
             Readiness.open(snapshot.behavior_digest, [],
               server: barrier,
               metadata_sources: [metadata_source]
             )

    Process.exit(source, :shutdown)

    assert eventually(fn -> Readiness.status(server: barrier) == {:error, :unavailable} end)
  end

  defp candidate_with_effectful_pack do
    %Candidate{
      schema_version: 1,
      contributions: [
        %Contribution{
          schema_version: 1,
          owner: %Owner{
            schema_version: 1,
            kind: :compiled_pack,
            id: "allbert_assist",
            application: :allbert_assist
          },
          implementation_module: __MODULE__,
          descriptor: %Descriptor{
            schema_version: 1,
            id: "allbert_assist",
            application: :allbert_assist,
            application_version: "1.3.2",
            capability_tier: :native,
            provenance: %{source: :signed_release, component: "beam-allbert-assist"},
            registry_order: 100
          },
          source_lane: :native,
          owner_order: %Order{schema_version: 1, namespace: :compiled_pack, value: 100},
          compatibility: %Compatibility{
            schema_version: 1,
            kind: :native,
            legacy_id: nil,
            alias_of: nil,
            trust: :trusted,
            enabled: true
          },
          callbacks: empty_callbacks()
        }
      ],
      action_bindings: [],
      compatibility_aliases: [],
      compatibility_diagnostics: []
    }
  end

  defp empty_candidate do
    %Candidate{
      schema_version: 1,
      contributions: [],
      action_bindings: [],
      compatibility_aliases: [],
      compatibility_diagnostics: []
    }
  end

  defp empty_callbacks do
    %{
      apps: [],
      actions: [],
      settings_fragments: [],
      settings_migrations: [],
      channels: [],
      surfaces: [],
      skill_roots: [],
      home_roots: [],
      jobs: [],
      stores: [],
      prompt_rules: [],
      intent_descriptors: [],
      cli_groups: [],
      release_assets: [],
      test_lanes: []
    }
  end

  defp eventually(assertion, attempts \\ 20)
  defp eventually(assertion, 0), do: assertion.()

  defp eventually(assertion, attempts) do
    if assertion.() do
      true
    else
      Process.sleep(10)
      eventually(assertion, attempts - 1)
    end
  end
end
