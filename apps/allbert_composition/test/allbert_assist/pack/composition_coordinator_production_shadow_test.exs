defmodule AllbertAssist.Pack.CompositionCoordinatorProductionShadowTest do
  use ExUnit.Case, async: false

  @moduletag :global_process_serial
  @moduletag timeout: 120_000

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.DevGates.V14M1RegistryShadowParity, as: ShadowParity

  alias AllbertAssist.Pack.{
    Canonical,
    CandidateBuilder,
    CompositionCoordinator,
    ProjectionProvider,
    Readiness
  }

  alias AllbertAssist.Pack.Registry, as: PackRegistry
  alias AllbertAssist.Pack.Supervisor, as: PackSupervisor
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.TestSupport.RegistryIsolationFixtures, as: Fixtures

  # v1.4 M8 re-froze this digest. Relocation moved the Security suite into the
  # kernel, so the kernel gate owner now declares the lane that suite carries,
  # and a gate-owner contribution is part of the Pack candidate. The change was
  # isolated before it was accepted: reverting only the lane declaration
  # restores the previous digest exactly, which proves the relocated files
  # themselves changed no contribution.
  # v1.4 M9 re-froze this digest. The notes_files pack became an umbrella sibling,
  # so its descriptor is a third row in the closed projection and its
  # contributions -- gate owner lane, settings fragment owner, skill root -- now
  # reach the candidate through the pack rather than through the residual. The
  # candidate legitimately changed; no contribution was added or removed, only
  # re-attributed to the application that owns it.
  # v1.4 M12 re-froze this digest. Telegram and email became umbrella siblings,
  # so the closed projection carries five rows instead of three and each pack's
  # contributions -- its gate owner lane, its settings fragment owner, and the
  # CLI group it now declares through cli_groups/0 -- reach the candidate through
  # the pack rather than through the residual. As at M9, no contribution was
  # added or removed, only re-attributed to the application that owns it.
  @expected_behavior_digest "2046202bfaa3e1bf65240d43d22d82bf810660439ca3a748d9720eb0f8473a00"
  @expected_bytes_sha256 "223e969e6fe89f6d187aacc974c1022cbd35c28acc2e386954af3185d6383f65"

  defmodule AppMetadataSupervisor do
    use GenServer
    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def init(:ok), do: {:ok, :ready}
  end

  defmodule PluginMetadataSupervisor do
    use GenServer
    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def init(:ok), do: {:ok, :ready}
  end

  defmodule AppBootstrap do
    use GenServer
    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def await_ready(__MODULE__, _timeout), do: :ok
    def completion_token(__MODULE__, _timeout), do: GenServer.call(__MODULE__, :token)
    def init(:ok), do: {:ok, make_ref()}

    def handle_call(:token, _from, token) do
      {:reply, {:ok, %{pid: self(), generation: 1, completion_token: token}}, token}
    end
  end

  defmodule PluginBootstrap do
    use GenServer
    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def completion_token(__MODULE__, _timeout), do: GenServer.call(__MODULE__, :token)
    def init(:ok), do: {:ok, make_ref()}

    def handle_call(:token, _from, token) do
      {:reply, {:ok, %{pid: self(), generation: 1, completion_token: token}}, token}
    end
  end

  defmodule AppRegistrySource do
    use GenServer
    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot, name: __MODULE__)

    def snapshot_and_subscribe(_subscriber, opts) do
      GenServer.call(Keyword.fetch!(opts, :server), :snapshot)
    end

    def bind_epoch(ref, generation, barrier_pid, opts) do
      GenServer.call(Keyword.fetch!(opts, :server), {:bind, ref, generation, barrier_pid})
    end

    def init(snapshot), do: {:ok, snapshot}

    def handle_call(:snapshot, _from, snapshot) do
      {:reply, {:ok, snapshot, make_ref()}, snapshot}
    end

    def handle_call({:bind, ref, generation, barrier_pid}, _from, snapshot) do
      {:reply, Readiness.bind_metadata(barrier_pid, self(), generation, ref), snapshot}
    end
  end

  defmodule PluginRegistrySource do
    use GenServer
    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot, name: __MODULE__)

    def snapshot_and_subscribe(_subscriber, opts) do
      GenServer.call(Keyword.fetch!(opts, :server), :snapshot)
    end

    def bind_epoch(ref, generation, barrier_pid, opts) do
      GenServer.call(Keyword.fetch!(opts, :server), {:bind, ref, generation, barrier_pid})
    end

    def init(snapshot), do: {:ok, snapshot}

    def handle_call(:snapshot, _from, snapshot) do
      {:reply, {:ok, snapshot, make_ref()}, snapshot}
    end

    def handle_call({:bind, ref, generation, barrier_pid}, _from, snapshot) do
      {:reply, Readiness.bind_metadata(barrier_pid, self(), generation, ref), snapshot}
    end
  end

  defmodule ShadowPackRegistry do
    def finalize(candidate, opts) do
      PackRegistry.finalize(candidate, Keyword.put(opts, :server, __MODULE__))
    end

    def snapshot, do: PackRegistry.snapshot(server: __MODULE__)
  end

  defmodule ShadowReadiness do
    def status, do: Readiness.status(server: __MODULE__)

    def open(digest, expected_ids, opts) do
      Readiness.open(digest, expected_ids, Keyword.put(opts, :server, __MODULE__))
    end

    def subscribe(pack_id), do: Readiness.subscribe(pack_id, server: __MODULE__)

    def ack(ref, digest) do
      Readiness.ack(ref, digest, server: __MODULE__, subscriber: self())
    end
  end

  test "M1.b production coordinator publishes the builder candidate authoritatively at post-token parity" do
    registry_context = Fixtures.start_shipped_registries(:m2_production_shadow)

    assert {:ok, app_snapshot, _app_ref} =
             AppRegistry.snapshot_and_subscribe(self(), registry_context[:app])

    assert {:ok, plugin_snapshot, _plugin_ref} =
             PluginRegistry.snapshot_and_subscribe(self(), registry_context[:plugin])

    start_supervised!({AppMetadataSupervisor, []})
    start_supervised!({PluginMetadataSupervisor, []})
    start_supervised!({AppBootstrap, []})
    start_supervised!({PluginBootstrap, []})
    start_supervised!({AppRegistrySource, app_snapshot})
    start_supervised!({PluginRegistrySource, plugin_snapshot})

    coordinator_name = Module.concat(__MODULE__, CoordinatorOwner)
    pack_supervisor_name = Module.concat(__MODULE__, ShadowPackSupervisor)

    start_supervised!(
      {PackSupervisor,
       name: pack_supervisor_name,
       registry: ShadowPackRegistry,
       readiness: ShadowReadiness,
       coordinator: coordinator_name}
    )

    assert {:ok, closed} = ProjectionProvider.closed()

    subscribers =
      closed.rows
      |> Enum.filter(&(&1.startup_role == :native_effectful))
      |> Enum.map(& &1.id)
      |> Enum.sort()
      |> Enum.map(&start_gate!/1)

    on_exit(fn -> Enum.each(subscribers, &send(&1, :stop)) end)

    coordinator =
      start_supervised!(
        {CompositionCoordinator,
         name: coordinator_name,
         projection_provider: ProjectionProvider,
         pack_supervisor: pack_supervisor_name,
         app_metadata_supervisor: AppMetadataSupervisor,
         app_bootstrap: AppBootstrap,
         plugin_metadata_supervisor: PluginMetadataSupervisor,
         plugin_bootstrap: PluginBootstrap,
         app_registry: AppRegistrySource,
         plugin_registry: PluginRegistrySource,
         candidate_builder: CandidateBuilder,
         pack_registry: ShadowPackRegistry,
         readiness: ShadowReadiness}
      )

    assert Process.alive?(coordinator)
    assert %{phase: :ready, behavior_digest: behavior_digest} = await_ready(coordinator_name)
    assert {:ok, coordinator_snapshot} = ShadowPackRegistry.snapshot()
    assert coordinator_snapshot.publication == :authoritative
    assert {:ok, coordinator_bytes} = Canonical.snapshot_bytes(coordinator_snapshot)

    assert {:ok, builder_candidate} =
             CandidateBuilder.build(closed, app_snapshot, plugin_snapshot)

    assert :ok = ShadowParity.verify_m0_bindings!(builder_candidate, ShadowParity.prepare_m0!())
    assert {:ok, builder_snapshot} = Canonical.build_snapshot(builder_candidate, :shadow)
    assert {:ok, builder_bytes} = Canonical.snapshot_bytes(builder_snapshot)

    assert coordinator_bytes == builder_bytes
    assert behavior_digest == builder_snapshot.behavior_digest

    assert Enum.map(builder_candidate.action_bindings, & &1.registry_order) ==
             Enum.to_list(1..281)

    bytes_sha256 = :crypto.hash(:sha256, coordinator_bytes) |> Base.encode16(case: :lower)
    assert behavior_digest == @expected_behavior_digest
    assert bytes_sha256 == @expected_bytes_sha256

    IO.puts(
      "v14-m2-production-shadow status=pass actions=281 behavior_digest=#{behavior_digest} " <>
        "canonical_bytes_sha256=#{bytes_sha256} canonical_bytes=#{byte_size(coordinator_bytes)}"
    )
  end

  defp start_gate!(pack_id) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, %{subscription_ref: ref}} = ShadowReadiness.subscribe(pack_id)
        send(parent, {:subscribed, pack_id})

        receive do
          {:allbert_pack_activate, _barrier_pid, ^ref, digest} ->
            :ok = ShadowReadiness.ack(ref, digest)
            send(parent, {:acked, pack_id})
        end

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:subscribed, ^pack_id}, 5_000
    pid
  end

  defp await_ready(server, attempts \\ 2_000)
  defp await_ready(_server, 0), do: flunk("production shadow coordinator did not become ready")

  defp await_ready(server, attempts) do
    case ShadowReadiness.status() do
      {:ok, %{phase: :ready}} ->
        CompositionCoordinator.status(server)

      _status ->
        Process.sleep(25)
        await_ready(server, attempts - 1)
    end
  end
end
