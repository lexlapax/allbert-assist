defmodule AllbertAssist.Pack.CompositionCoordinatorTest do
  use ExUnit.Case, async: false

  @moduletag :global_process_serial

  alias AllbertAssist.App.Registry.MetadataSnapshot, as: AppSnapshot
  alias AllbertAssist.Kernel.Contract
  alias AllbertAssist.Pack.CompositionCoordinator
  alias AllbertAssist.Pack.Projection.Closed
  alias AllbertAssist.Pack.Residual
  alias AllbertAssist.Plugin.Registry.MetadataSnapshot, as: PluginSnapshot

  defmodule BootstrapStub do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def await_ready(__MODULE__, _timeout), do: :ok
    def completion_token(__MODULE__, _timeout), do: GenServer.call(__MODULE__, :completion_token)
    def put_completion_pid(pid), do: GenServer.call(__MODULE__, {:completion_pid, pid})
    def init(:ok), do: {:ok, %{completion_pid: nil, token: make_ref()}}

    def handle_call(:completion_token, _from, state) do
      {:reply,
       {:ok,
        %{pid: state.completion_pid || self(), generation: 1, completion_token: state.token}},
       state}
    end

    def handle_call({:completion_pid, pid}, _from, state),
      do: {:reply, :ok, %{state | completion_pid: pid}}
  end

  defmodule PluginBootstrapStub do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def completion_token(__MODULE__, _timeout), do: GenServer.call(__MODULE__, :completion_token)
    def init(:ok), do: {:ok, make_ref()}

    def handle_call(:completion_token, _from, token) do
      {:reply, {:ok, %{pid: self(), generation: 1, completion_token: token}}, token}
    end
  end

  defmodule PackSupervisorStub do
    use GenServer
    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def init(:ok), do: {:ok, :ready}
  end

  defmodule AppMetadataSupervisorStub do
    use GenServer
    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def init(:ok), do: {:ok, :ready}
  end

  defmodule PluginMetadataSupervisorStub do
    use GenServer
    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def init(:ok), do: {:ok, :ready}
  end

  defmodule AppRegistryStub do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def snapshot_and_subscribe(_subscriber, opts \\ []),
      do: GenServer.call(Keyword.get(opts, :server, __MODULE__), :snapshot)

    def bind_epoch(ref, generation, barrier_pid, opts \\ []) do
      GenServer.call(
        Keyword.get(opts, :server, __MODULE__),
        {:bind, ref, generation, barrier_pid}
      )
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, opts) do
      {:reply, {:ok, Keyword.fetch!(opts, :snapshot), Keyword.fetch!(opts, :ref)}, opts}
    end

    def handle_call({:bind, ref, generation, barrier_pid}, _from, opts) do
      send(Keyword.fetch!(opts, :parent), {:app_bind, ref, generation, barrier_pid})
      {:reply, Keyword.get(opts, :bind_result, :ok), opts}
    end
  end

  defmodule PluginRegistryStub do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def snapshot_and_subscribe(_subscriber, opts \\ []),
      do: GenServer.call(Keyword.get(opts, :server, __MODULE__), :snapshot)

    def bind_epoch(ref, generation, barrier_pid, opts \\ []) do
      GenServer.call(
        Keyword.get(opts, :server, __MODULE__),
        {:bind, ref, generation, barrier_pid}
      )
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, opts) do
      {:reply, {:ok, Keyword.fetch!(opts, :snapshot), Keyword.fetch!(opts, :ref)}, opts}
    end

    def handle_call({:bind, ref, generation, barrier_pid}, _from, opts) do
      send(Keyword.fetch!(opts, :parent), {:plugin_bind, ref, generation, barrier_pid})
      {:reply, Keyword.get(opts, :bind_result, :ok), opts}
    end
  end

  defmodule ProjectionProviderStub do
    def closed, do: {:ok, build_closed()}

    defp build_closed do
      %Closed{
        schema_version: 1,
        closed_applications: [],
        pack_applications: [],
        rows: [],
        projection_sha256: String.duplicate("a", 64),
        closure_sha256: String.duplicate("b", 64)
      }
    end
  end

  defmodule ContractOwnerStub do
    @key {__MODULE__, :state}

    def put(state), do: :persistent_term.put(@key, state)
    def clear, do: :persistent_term.erase(@key)

    def bind(__MODULE__, providers, generation, barrier_pid) do
      state = :persistent_term.get(@key)
      send(state.parent, {:contract_bind, providers, generation, barrier_pid})
      state.result
    end
  end

  defmodule CandidateBuilderStub do
    @key {__MODULE__, :candidate}

    def put(candidate), do: :persistent_term.put(@key, candidate)
    def clear, do: :persistent_term.erase(@key)

    def build(_closed, _apps, _plugins) do
      case :persistent_term.get(@key) do
        {:error, _reason} = error -> error
        candidate -> {:ok, candidate}
      end
    end
  end

  defmodule PackRegistryStub do
    @key {__MODULE__, :parent}

    def put_parent(parent), do: :persistent_term.put(@key, parent)
    def clear, do: :persistent_term.erase(@key)

    def finalize(candidate, effectful_ids: effectful_ids) do
      send(:persistent_term.get(@key), {:finalize, candidate, effectful_ids})
      {:ok, %{behavior_digest: String.duplicate("c", 64)}}
    end
  end

  defmodule ReadinessStub do
    @key {__MODULE__, :state}

    def put(state), do: :persistent_term.put(@key, state)
    def clear, do: :persistent_term.erase(@key)
    def status, do: {:ok, %{barrier_pid: :persistent_term.get(@key).barrier}}

    def open(digest, expected_ids, opts) do
      state = :persistent_term.get(@key)
      metadata_sources = Keyword.fetch!(opts, :metadata_sources)
      send(state.parent, {:open, digest, expected_ids, metadata_sources})
      {:ok, %{barrier_pid: state.barrier, snapshot_digest: digest, phase: :ready}}
    end
  end

  setup do
    previous_trap_exit = Process.flag(:trap_exit, true)

    barrier =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    app_ref = make_ref()
    plugin_ref = make_ref()

    CandidateBuilderStub.put(:candidate)
    PackRegistryStub.put_parent(self())
    ReadinessStub.put(%{parent: self(), barrier: barrier})
    ContractOwnerStub.put(%{parent: self(), result: {:ok, :bound}})

    pack_supervisor = start_supervised!(PackSupervisorStub)
    app_metadata_supervisor = start_supervised!(AppMetadataSupervisorStub)
    app_bootstrap = start_supervised!(BootstrapStub)
    plugin_bootstrap = start_supervised!(PluginBootstrapStub)

    app_registry =
      start_supervised!(
        {AppRegistryStub,
         parent: self(),
         ref: app_ref,
         snapshot: %AppSnapshot{schema_version: 1, generation: 11, entries: []}}
      )

    plugin_metadata_supervisor = start_supervised!(PluginMetadataSupervisorStub)

    plugin_registry =
      start_supervised!(
        {PluginRegistryStub,
         parent: self(),
         ref: plugin_ref,
         snapshot: %PluginSnapshot{schema_version: 1, generation: 17, entries: []}}
      )

    on_exit(fn ->
      CandidateBuilderStub.clear()
      PackRegistryStub.clear()
      ReadinessStub.clear()
      ContractOwnerStub.clear()
      if Process.alive?(barrier), do: Process.exit(barrier, :kill)
      Process.flag(:trap_exit, previous_trap_exit)
    end)

    %{
      barrier: barrier,
      app_ref: app_ref,
      plugin_ref: plugin_ref,
      pack_supervisor: pack_supervisor,
      app_metadata_supervisor: app_metadata_supervisor,
      app_registry: app_registry,
      app_bootstrap: app_bootstrap,
      plugin_metadata_supervisor: plugin_metadata_supervisor,
      plugin_registry: plugin_registry,
      plugin_bootstrap: plugin_bootstrap
    }
  end

  test "M1.b opens the generation-bound builder candidate", context do
    %{app_ref: app_ref, barrier: barrier, plugin_ref: plugin_ref} = context
    coordinator = start_coordinator()

    assert_receive {:finalize, :candidate, []}
    assert_receive {:app_bind, ^app_ref, 11, ^barrier}
    assert_receive {:plugin_bind, ^plugin_ref, 17, ^barrier}

    assert_receive {:open, digest, [], metadata_sources}
    assert digest == String.duplicate("c", 64)

    assert [
             {app_pid, 11, ^app_ref},
             {plugin_pid, 17, ^plugin_ref}
           ] = metadata_sources

    assert app_pid == Process.whereis(AppRegistryStub)
    assert plugin_pid == Process.whereis(PluginRegistryStub)

    assert %{
             phase: :ready,
             behavior_digest: ^digest,
             projection_sha256: projection_sha,
             epoch: %{barrier_pid: ^barrier, snapshot_digest: ^digest},
             source_generations: %{app: 11, plugin: 17},
             bootstrap_generations: %{app: 1, plugin: 1}
           } = CompositionCoordinator.status(coordinator)

    assert projection_sha == String.duplicate("a", 64)
  end

  test "M7.1 binds the kernel contract set to the finalized generation before effects open",
       context do
    %{barrier: barrier} = context
    _coordinator = start_coordinator()

    # Order matters: the snapshot is finalized, then the contract set is bound
    # against its digest, and only then does the readiness barrier open. An
    # effect must never run against an unbound kernel.
    assert_receive {:finalize, :candidate, []}
    assert_receive {:contract_bind, providers, digest, ^barrier}
    assert_receive {:open, ^digest, [], _sources}

    assert digest == String.duplicate("c", 64)
    # The stub projection carries no descriptor rows, so no provider is
    # invented on the way through.
    assert providers == []
  end

  test "a rejected contract set fails composition before the barrier opens", context do
    %{barrier: _barrier} = context
    ContractOwnerStub.put(%{parent: self(), result: {:error, {:missing_contracts, [:settings]}}})

    {coordinator, ref} = monitored_coordinator()

    assert_receive {:DOWN, ^ref, :process, ^coordinator,
                    {:composition_failed, {:missing_contracts, [:settings]}}}

    assert_receive {:contract_bind, _providers, _digest, _barrier}
    refute_receive {:open, _, _, _}
  end

  test "the shipped residual pack supplies every contract in the closed set" do
    # The binder rejects an incomplete set, so a contract added to the kernel
    # without an owner supplying it would fail composition at boot. Assert the
    # pairing here rather than discovering it as a startup failure.
    declared = Residual.kernel_contracts()

    assert Enum.map(declared, &elem(&1, 0)) |> Enum.sort() ==
             Contract.ids()

    for {contract, implementation} <- declared do
      assert Code.ensure_loaded?(implementation)

      for {fun, arity} <- Contract.required_callbacks(contract) do
        assert function_exported?(implementation, fun, arity),
               "#{inspect(implementation)} does not export #{fun}/#{arity} for #{contract}"
      end
    end
  end

  test "builder rejection fails closed before finalization or epoch open" do
    CandidateBuilderStub.put({:error, :candidate_rejected})
    {coordinator, ref} = monitored_coordinator()

    assert_receive {:DOWN, ^ref, :process, ^coordinator,
                    {:composition_failed, :candidate_rejected}}

    refute_receive {:finalize, _, _}
    refute_receive {:open, _, _, _}
  end

  test "stale metadata bind fails closed before readiness open", context do
    %{app_ref: app_ref, barrier: barrier} = context
    stop_supervised!(AppRegistryStub)

    start_supervised!(
      {AppRegistryStub,
       parent: self(),
       ref: app_ref,
       bind_result: {:error, :stale_epoch},
       snapshot: %AppSnapshot{schema_version: 1, generation: 11, entries: []}}
    )

    {coordinator, ref} = monitored_coordinator()

    assert_receive {:app_bind, ^app_ref, 11, ^barrier}
    assert_receive {:DOWN, ^ref, :process, ^coordinator, {:composition_failed, :stale_epoch}}
    refute_receive {:finalize, _, _}
    refute_receive {:open, _, _, _}
  end

  test "mismatched app bootstrap completion pid fails before finalization" do
    BootstrapStub.put_completion_pid(self())
    {coordinator, ref} = monitored_coordinator()

    assert_receive {:DOWN, ^ref, :process, ^coordinator,
                    {:composition_failed, :composition_input_mismatch}}

    refute_receive {:finalize, _, _}
  end

  test "transient metadata bootstrap loss retries without exhausting supervision" do
    stop_supervised!(BootstrapStub)
    {coordinator, ref} = monitored_coordinator()

    refute_receive {:DOWN, ^ref, :process, ^coordinator, _reason}, 250
    refute_receive {:finalize, _, _}

    start_supervised!(BootstrapStub)

    assert_receive {:finalize, :candidate, []}, 1_000
    assert_receive {:open, _, [], _}, 1_000
    assert Process.alive?(coordinator)
  end

  for {label, context_key, expected_owner} <- [
        {"kernel Pack supervisor", :pack_supervisor, PackSupervisorStub},
        {"kernel readiness barrier", :barrier, :pid},
        {"App MetadataSupervisor", :app_metadata_supervisor, AppMetadataSupervisorStub},
        {"App Registry", :app_registry, AppRegistryStub},
        {"App Bootstrap", :app_bootstrap, BootstrapStub},
        {"Plugin MetadataSupervisor", :plugin_metadata_supervisor, PluginMetadataSupervisorStub},
        {"Plugin Registry", :plugin_registry, PluginRegistryStub},
        {"Plugin Bootstrap", :plugin_bootstrap, PluginBootstrapStub}
      ] do
    test "monitored #{label} DOWN terminates a ready coordinator", context do
      {coordinator, ref} = monitored_coordinator()
      assert_receive {:open, _, [], _}

      stopped_pid = Map.fetch!(context, unquote(context_key))
      Process.exit(stopped_pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^coordinator,
                      {:composition_input_down, owner, stable_reason}}

      assert stable_reason in [:killed, :unexpected]

      assert owner ==
               if(unquote(expected_owner) == :pid, do: stopped_pid, else: unquote(expected_owner))
    end
  end

  defp start_coordinator do
    {:ok, coordinator} =
      CompositionCoordinator.start_link(
        name: {:global, {__MODULE__, make_ref()}},
        projection_provider: ProjectionProviderStub,
        pack_supervisor: PackSupervisorStub,
        app_metadata_supervisor: AppMetadataSupervisorStub,
        app_bootstrap: BootstrapStub,
        plugin_metadata_supervisor: PluginMetadataSupervisorStub,
        plugin_bootstrap: PluginBootstrapStub,
        app_registry: AppRegistryStub,
        plugin_registry: PluginRegistryStub,
        candidate_builder: CandidateBuilderStub,
        pack_registry: PackRegistryStub,
        readiness: ReadinessStub,
        contract_owner: ContractOwnerStub
      )

    on_exit(fn ->
      if Process.alive?(coordinator), do: GenServer.stop(coordinator, :normal)
    end)

    coordinator
  end

  defp monitored_coordinator do
    coordinator = start_coordinator()
    {coordinator, Process.monitor(coordinator)}
  end
end
