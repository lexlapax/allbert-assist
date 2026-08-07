defmodule AllbertAssist.App.RegistryTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Multiply
  alias AllbertAssist.App.Registry
  alias AllbertAssist.App.Registry.{MetadataEntry, MetadataSnapshot}
  alias AllbertAssist.App.Validator
  alias AllbertAssist.Pack.Readiness
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node

  defmodule FixtureApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :fixture_app

    @impl true
    def display_name, do: "Fixture App"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def actions, do: [DirectAnswer]

    @impl true
    def skill_paths, do: [Path.join(System.tmp_dir!(), "fixture-app-skills")]

    @impl true
    def surfaces do
      [
        %{
          id: :home,
          label: "Fixture",
          path: "/fixture",
          app_id: :fixture_app,
          icon: "box",
          description: "Fixture app"
        }
      ]
    end
  end

  defmodule EmptyApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :empty_app

    @impl true
    def display_name, do: "Empty App"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def validate(_opts), do: :ok
  end

  defmodule ProviderApp do
    use AllbertAssist.App
    use AllbertAssist.App.SurfaceProvider

    @impl true
    def app_id, do: :provider_app

    @impl true
    def display_name, do: "Provider App"

    @impl true
    def version, do: "0.18.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def agents, do: [AllbertAssist.Agents.IntentAgent]

    @impl true
    def signals, do: %{emits: ["provider.app.started"], subscribes: []}

    @impl true
    def settings_schema do
      [%{key: "apps.provider_app.enabled", type: :boolean, default: false}]
    end

    @impl true
    def memory_namespace do
      %{
        app_id: :provider_app,
        namespace: :provider_app,
        writable: false,
        description: "Provider fixture namespace."
      }
    end

    @impl true
    def surfaces do
      [
        %Surface{
          id: :home,
          app_id: :provider_app,
          label: "Provider Home",
          path: "/provider",
          kind: :route,
          status: :available,
          nodes: [%Node{id: "root", component: :route}],
          fallback_text: "Provider home."
        }
      ]
    end

    def surface_catalog, do: [%{component: :route, allowed_props: [], allowed_bindings: []}]
  end

  defmodule DuplicateRouteProviderApp do
    use AllbertAssist.App
    use AllbertAssist.App.SurfaceProvider

    @impl true
    def app_id, do: :duplicate_route_provider_app

    @impl true
    def display_name, do: "Duplicate Route Provider"

    @impl true
    def version, do: "0.18.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def surfaces do
      [
        %Surface{
          id: :other_home,
          app_id: :duplicate_route_provider_app,
          label: "Duplicate Route",
          path: "/provider",
          kind: :route,
          status: :available,
          nodes: [%Node{id: "root", component: :route}],
          fallback_text: "Duplicate route."
        }
      ]
    end

    def surface_catalog, do: [%{component: :route, allowed_props: [], allowed_bindings: []}]
  end

  defmodule PanelProviderApp do
    use AllbertAssist.App
    use AllbertAssist.App.SurfaceProvider

    @impl true
    def app_id, do: :panel_provider_app

    @impl true
    def display_name, do: "Panel Provider"

    @impl true
    def version, do: "0.32.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def surfaces do
      [
        %Surface{
          id: :summary_panel,
          app_id: :panel_provider_app,
          label: "Summary Panel",
          path: "/workspace",
          kind: :panel,
          zone: :canvas_panels,
          status: :available,
          nodes: [%Node{id: "summary-panel-root", component: :panel}],
          fallback_text: "Summary panel."
        }
      ]
    end

    def surface_catalog, do: []
  end

  defmodule AnotherPanelProviderApp do
    use AllbertAssist.App
    use AllbertAssist.App.SurfaceProvider

    @impl true
    def app_id, do: :another_panel_provider_app

    @impl true
    def display_name, do: "Another Panel Provider"

    @impl true
    def version, do: "0.32.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def surfaces do
      [
        %Surface{
          id: :activity_panel,
          app_id: :another_panel_provider_app,
          label: "Activity Panel",
          path: "/workspace",
          kind: :panel,
          zone: :context_rail,
          status: :available,
          nodes: [%Node{id: "activity-panel-root", component: :panel}],
          fallback_text: "Activity panel."
        }
      ]
    end

    def surface_catalog, do: []
  end

  defmodule DuplicateSurfaceApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :duplicate_surface_app

    @impl true
    def display_name, do: "Duplicate Surface App"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def surfaces do
      [
        %{
          id: :home,
          label: "Duplicate",
          path: "/duplicate",
          app_id: :duplicate_surface_app
        }
      ]
    end
  end

  defmodule BrokenValidationApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :broken_validation_app

    @impl true
    def display_name, do: "Broken Validation"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def validate(_opts) do
      {:error, [%{kind: :broken_fixture, message: "broken fixture", detail: %{safe: true}}]}
    end
  end

  defmodule UnknownActionApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :unknown_action_app

    @impl true
    def display_name, do: "Unknown Action"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def actions, do: [Multiply]
  end

  defmodule ChildApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :child_app

    @impl true
    def display_name, do: "Child App"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def child_spec(_opts) do
      %{
        id: :child_app_agent,
        start: {Agent, :start_link, [fn -> :ok end]}
      }
    end
  end

  defmodule BrokenChildApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :broken_child_app

    @impl true
    def display_name, do: "Broken Child App"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def child_spec(_opts), do: raise("child boom")
  end

  defmodule ReadyBarrier do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, :ok}

    @impl true
    def handle_call({:validate_activation, _context}, _from, state),
      do: {:reply, :ok, state}
  end

  setup do
    registry = :"app_registry_#{System.unique_integer([:positive])}"
    dynamic_supervisor = :"app_dynamic_supervisor_#{System.unique_integer([:positive])}"
    table = :"app_registry_table_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec({AllbertAssist.App.DynamicSupervisor, name: dynamic_supervisor},
        id: dynamic_supervisor
      )
    )

    start_supervised!(
      Supervisor.child_spec(
        {Registry, name: registry, table_name: table, dynamic_supervisor: dynamic_supervisor},
        id: registry
      )
    )

    {:ok, opts: [server: registry], dynamic_supervisor: dynamic_supervisor}
  end

  test "use AllbertAssist.App supplies inert defaults" do
    assert EmptyApp.agents() == []
    assert EmptyApp.actions() == []
    assert EmptyApp.signals() == %{emits: [], subscribes: []}
    assert EmptyApp.skill_paths() == []
    assert EmptyApp.settings_schema() == []
    assert EmptyApp.memory_namespace() == nil
    assert EmptyApp.surfaces() == []
    assert EmptyApp.child_spec([]) == :ignore
  end

  test "validator accepts the lite app contract and normalizes fields" do
    assert {:ok, attrs} = Validator.validate(FixtureApp, [])
    assert attrs.app_id == :fixture_app
    assert attrs.display_name == "Fixture App"
    assert attrs.actions == [DirectAnswer]
    assert [%{id: :home, app_id: :fixture_app, path: "/fixture"}] = attrs.surfaces
  end

  test "registers, looks up, flattens surfaces, and unregisters app entries", %{
    opts: opts,
    dynamic_supervisor: dynamic_supervisor
  } do
    assert {:ok, :fixture_app} = Registry.register(FixtureApp, opts)

    assert {:ok, entry} = Registry.lookup(:fixture_app, opts)
    assert entry.app_id == :fixture_app
    assert entry.module == FixtureApp
    assert entry.child_id == :ignore

    assert [%{app_id: :fixture_app, path: path}] = Registry.registered_skill_paths(opts)
    assert path == Path.join(System.tmp_dir!(), "fixture-app-skills")

    assert [%{id: :home, app_id: :fixture_app}] = Registry.registered_surfaces(opts)
    assert Registry.actions_for(:fixture_app, opts) == [DirectAnswer]
    assert Registry.app_id_for_action(DirectAnswer, opts) == :fixture_app
    assert Registry.known_app_id?(:fixture_app, opts)
    assert {:ok, :fixture_app} = Registry.normalize_app_id("fixture_app", opts)

    assert :ok = Registry.unregister(:fixture_app, opts)
    assert {:error, :not_found} = Registry.lookup(:fixture_app, opts)
    assert Registry.registered_apps(opts) == []
    assert DynamicSupervisor.which_children(dynamic_supervisor) == []
  end

  test "ordered entry snapshots preserve registration order without mutation", %{opts: opts} do
    assert {:ok, :empty_app} =
             Registry.register(EmptyApp, Keyword.put(opts, :side_effects, false))

    assert {:ok, entry} = Registry.lookup(:empty_app, opts)
    before = :sys.get_state(Keyword.fetch!(opts, :server))

    assert {:ok, [^entry]} = Registry.ordered_entries(opts)
    assert :sys.get_state(Keyword.fetch!(opts, :server)) == before
  end

  test "ordered entry snapshots report an unavailable selected registry" do
    assert Process.whereis(:app_registry_missing_snapshot_server) == nil

    assert {:error, :unavailable} =
             Registry.ordered_entries(server: :app_registry_missing_snapshot_server)
  end

  test "generation snapshots contain only structural metadata and notify stale captures", %{
    opts: opts
  } do
    registry = Keyword.fetch!(opts, :server)
    registry_pid = Process.whereis(registry)

    assert {:ok, %MetadataSnapshot{generation: 0, entries: []}, first_ref} =
             Registry.snapshot_and_subscribe(self(), opts)

    assert {:ok, :empty_app} =
             Registry.register(EmptyApp, Keyword.put(opts, :side_effects, false))

    assert_receive {:allbert_metadata_generation_changed, ^registry_pid, ^first_ref, 1}

    assert {:ok,
            %MetadataSnapshot{
              schema_version: 1,
              generation: 1,
              entries: [%MetadataEntry{app_id: :empty_app} = metadata]
            }, second_ref} = Registry.snapshot_and_subscribe(self(), opts)

    assert is_reference(second_ref)
    refute Map.has_key?(metadata, :child_pid)
    refute Map.has_key?(metadata, :registered_at_ms)

    assert {:error, {:app_id_taken, :empty_app}} =
             Registry.register(EmptyApp, Keyword.put(opts, :side_effects, false))

    refute_receive {:allbert_metadata_generation_changed, ^registry_pid, ^second_ref, _generation}

    assert {:ok, %MetadataSnapshot{generation: 1}, _latest_ref} =
             Registry.snapshot_and_subscribe(self(), opts)
  end

  test "bound metadata mutation invalidates the exact barrier tuple before committing", %{
    opts: opts
  } do
    barrier =
      start_supervised!(
        Supervisor.child_spec({Readiness, name: nil, coordinator: self()},
          id: {:app_metadata_barrier, System.unique_integer([:positive])}
        )
      )

    assert {:ok, %MetadataSnapshot{generation: 0}, subscription_ref} =
             Registry.snapshot_and_subscribe(self(), opts)

    assert :ok = Registry.bind_epoch(subscription_ref, 0, barrier, opts)

    assert {:ok, :empty_app} =
             Registry.register(EmptyApp, Keyword.put(opts, :side_effects, false))

    assert {:error, :stale_generation} =
             Registry.bind_epoch(subscription_ref, 0, barrier, opts)

    assert {:ok, %MetadataSnapshot{generation: 1}, next_ref} =
             Registry.snapshot_and_subscribe(self(), opts)

    assert :ok = Registry.bind_epoch(next_ref, 1, barrier, opts)
  end

  test "stores and exposes full v0.18 contract fields", %{opts: opts} do
    assert {:ok, :provider_app} = Registry.register(ProviderApp, opts)

    assert {:ok, entry} = Registry.lookup(:provider_app, opts)
    assert entry.agents == [AllbertAssist.Agents.IntentAgent]
    assert entry.signals.emits == ["provider.app.started"]
    assert [%{key: "apps.provider_app.enabled"}] = entry.settings_schema
    assert %{namespace: :provider_app, writable: false} = entry.memory_namespace
    assert entry.surface_provider == ProviderApp
    assert [%Surface{id: :home}] = entry.provider_surfaces

    assert [%{app_id: :provider_app, module: AllbertAssist.Agents.IntentAgent}] =
             Registry.registered_agents(opts)

    assert [%{app_id: :provider_app, emits: ["provider.app.started"]}] =
             Registry.registered_signals(opts)

    assert [%{app_id: :provider_app, key: "apps.provider_app.enabled"}] =
             Registry.registered_settings_schema(opts)

    assert [%{app_id: :provider_app, namespace: :provider_app, writable: false}] =
             Registry.registered_memory_namespaces(opts)

    assert [%{app_id: :provider_app, module: ProviderApp, surfaces: [%Surface{id: :home}]}] =
             Registry.registered_surface_providers(opts)

    assert [%{id: :home, path: "/provider", provider?: true}] = Registry.registered_surfaces(opts)
  end

  test "cross-app duplicate provider route paths are diagnostics only", %{opts: opts} do
    assert {:ok, :provider_app} = Registry.register(ProviderApp, opts)

    assert {:ok, :duplicate_route_provider_app} =
             Registry.register(DuplicateRouteProviderApp, opts)

    assert %{
             duplicate_route_provider_app: [
               %{
                 kind: :duplicate_route_path,
                 detail: %{path: "/provider", app_id: :duplicate_route_provider_app}
               }
             ]
           } = Registry.diagnostics(opts)
  end

  test "panel surfaces may share the workspace path without route diagnostics", %{opts: opts} do
    assert {:ok, :panel_provider_app} = Registry.register(PanelProviderApp, opts)
    assert {:ok, :another_panel_provider_app} = Registry.register(AnotherPanelProviderApp, opts)

    assert Registry.diagnostics(opts) == %{}
  end

  test "rejects duplicate app ids without disturbing existing registration", %{opts: opts} do
    assert {:ok, :empty_app} = Registry.register(EmptyApp, opts)
    assert {:error, {:app_id_taken, :empty_app}} = Registry.register(EmptyApp, opts)

    assert [%{app_id: :empty_app}] = Registry.registered_apps(opts)
  end

  test "records validation and shape failures without creating entries", %{opts: opts} do
    assert {:error, {:validation_failed, BrokenValidationApp}} =
             Registry.register(BrokenValidationApp, opts)

    assert %{broken_validation_app: [%{kind: :broken_fixture}]} = Registry.diagnostics(opts)
    assert {:error, :not_found} = Registry.lookup(:broken_validation_app, opts)

    assert {:error, {:unknown_action_module, Multiply}} =
             Registry.register(UnknownActionApp, opts)

    assert {:error, :not_found} = Registry.lookup(:unknown_action_app, opts)
  end

  test "records cross-app surface id duplicates without rejecting registration", %{opts: opts} do
    assert {:ok, :fixture_app} = Registry.register(FixtureApp, opts)
    assert {:ok, :duplicate_surface_app} = Registry.register(DuplicateSurfaceApp, opts)

    assert {:ok, %{app_id: :duplicate_surface_app}} =
             Registry.lookup(:duplicate_surface_app, opts)

    assert %{
             duplicate_surface_app: [
               %{
                 kind: :duplicate_surface_id,
                 detail: %{surface_id: :home, app_id: :duplicate_surface_app}
               }
             ]
           } = Registry.diagnostics(opts)
  end

  test "starts and terminates app children by stable child id", %{
    opts: opts,
    dynamic_supervisor: dynamic_supervisor
  } do
    assert {:ok, :child_app} = Registry.register(ChildApp, opts)
    assert {:ok, entry} = Registry.lookup(:child_app, opts)
    assert entry.child_id == :child_app_agent
    assert is_pid(entry.child_pid)

    assert [{:undefined, pid, :worker, [Agent]}] =
             DynamicSupervisor.which_children(dynamic_supervisor)

    assert is_pid(pid)
    assert pid == entry.child_pid

    assert :ok = Registry.unregister(:child_app, opts)
    assert DynamicSupervisor.which_children(dynamic_supervisor) == []
  end

  test "metadata registration stages a non-ignore child without starting it", %{
    opts: opts,
    dynamic_supervisor: dynamic_supervisor
  } do
    assert {:ok, :child_app} = Registry.register_metadata(ChildApp, opts)
    assert DynamicSupervisor.which_children(dynamic_supervisor) == []

    assert {:ok, entry} = Registry.lookup(:child_app, opts)
    assert entry.child_id == :child_app_agent
    assert entry.child_pid == nil

    assert [%{app_id: :child_app, child_spec: %{id: :child_app_agent}}] =
             Registry.staged_child_specs(opts)
  end

  test "activated staged children remain available to rebuild in a replacement epoch", %{
    opts: opts,
    dynamic_supervisor: dynamic_supervisor
  } do
    barrier = start_supervised!(ReadyBarrier)

    context = %AllbertAssist.Pack.ActivationContext{
      schema_version: 1,
      pack_id: "allbert_assist",
      gate_pid: self(),
      barrier_pid: barrier,
      subscription_ref: make_ref(),
      snapshot_digest: String.duplicate("a", 64)
    }

    carrier = [allbert_pack_activation: context]

    assert {:ok, :child_app} = Registry.register_metadata(ChildApp, opts)
    assert :ok = Registry.activate_staged_children(carrier, opts)

    assert [{:undefined, first_child, :worker, [Agent]}] =
             DynamicSupervisor.which_children(dynamic_supervisor)

    first_dynamic_supervisor = Process.whereis(dynamic_supervisor)
    Process.exit(first_dynamic_supervisor, :kill)

    assert_eventually(fn ->
      replacement_dynamic_supervisor = Process.whereis(dynamic_supervisor)
      assert is_pid(replacement_dynamic_supervisor)
      refute replacement_dynamic_supervisor == first_dynamic_supervisor
    end)

    assert_eventually(fn -> assert DynamicSupervisor.which_children(dynamic_supervisor) == [] end)

    assert :ok = Registry.activate_staged_children(carrier, opts)

    assert [{:undefined, replacement_child, :worker, [Agent]}] =
             DynamicSupervisor.which_children(dynamic_supervisor)

    refute replacement_child == first_child

    assert [%{app_id: :child_app, child_spec: %{id: :child_app_agent}}] =
             Registry.staged_child_specs(opts)
  end

  test "child-spec failures are diagnostics only and leave other apps readable", %{opts: opts} do
    assert {:ok, :empty_app} = Registry.register(EmptyApp, opts)
    assert {:error, {:child_spec_failed, "child boom"}} = Registry.register(BrokenChildApp, opts)

    assert {:ok, %{app_id: :empty_app}} = Registry.lookup(:empty_app, opts)
    assert {:error, :not_found} = Registry.lookup(:broken_child_app, opts)

    assert %{broken_child_app: [%{kind: :child_spec_failed}]} = Registry.diagnostics(opts)
  end

  test "normalizes only known app ids and never creates unknown atoms", %{opts: opts} do
    assert {:ok, nil} = Registry.normalize_app_id(nil, opts)
    assert {:ok, nil} = Registry.normalize_app_id("", opts)
    assert {:ok, nil} = Registry.normalize_app_id("none", opts)
    assert {:error, :unknown_app} = Registry.normalize_app_id(:fixture_app, opts)

    assert {:ok, :fixture_app} = Registry.register(FixtureApp, opts)
    assert {:ok, :fixture_app} = Registry.normalize_app_id(:fixture_app, opts)
    assert {:ok, :fixture_app} = Registry.normalize_app_id("Fixture_App", opts)

    unknown = "__allbert_unknown_app_#{System.unique_integer([:positive])}__"
    assert {:error, :unknown_app} = Registry.normalize_app_id(unknown, opts)

    assert_raise ArgumentError, fn ->
      String.to_existing_atom(unknown)
    end
  end

  test "disabled registry reads as empty and rejects writes" do
    registry = :"app_registry_disabled_#{System.unique_integer([:positive])}"
    table = :"app_registry_disabled_table_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec({Registry, name: registry, table_name: table, enabled?: false},
        id: registry
      )
    )

    opts = [server: registry]

    assert {:error, :disabled} = Registry.register(EmptyApp, opts)
    assert {:error, :not_found} = Registry.lookup(:empty_app, opts)
    assert Registry.registered_apps(opts) == []
    refute Registry.known_app_id?(:empty_app, opts)
  end

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
