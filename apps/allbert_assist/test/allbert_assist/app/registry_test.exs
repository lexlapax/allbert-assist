defmodule AllbertAssist.App.RegistryTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Multiply
  alias AllbertAssist.App.Registry
  alias AllbertAssist.App.Validator

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
    assert EmptyApp.actions() == []
    assert EmptyApp.skill_paths() == []
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
end
