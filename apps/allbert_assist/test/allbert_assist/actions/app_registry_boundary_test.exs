defmodule AllbertAssist.Actions.AppRegistryBoundaryTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.DynamicPlugins.ActionsOverlay

  defmodule ScopedAction do
    use Jido.Action,
      name: "vanishing_scoped_action",
      description: "Test-only app-scoped action.",
      schema: []

    def capability do
      %{
        permission: :read_only,
        exposure: :internal,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required
      }
    end

    @impl true
    def run(_params, _context), do: raise("app-scoped action must not execute")
  end

  defmodule VanishingAppRegistry do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, 0)
    def init(count), do: {:ok, count}

    def handle_call({:app_id_for_action, _module}, _from, count),
      do: {:reply, :vanishing_app, count + 1}

    def handle_call({:known_app_id?, :vanishing_app}, _from, count),
      do: {:reply, false, count}

    def handle_call(_message, _from, count), do: {:reply, nil, count}
  end

  test "Runner re-proves live app membership immediately before dispatch" do
    registry = start_supervised!(VanishingAppRegistry)
    overlay = :"app_registry_boundary_overlay_#{System.unique_integer([:positive])}"

    start_supervised!(Supervisor.child_spec({ActionsOverlay, name: overlay}, id: overlay))

    assert :ok =
             ActionsOverlay.register_many(
               [
                 %{
                   module: ScopedAction,
                   slug: "app-registry-boundary",
                   revision: "test",
                   exposure: :internal,
                   app_id: :vanishing_app
                 }
               ],
               server: overlay,
               existing_names: ActionsRegistry.names()
             )

    assert {:ok, response} =
             Runner.run("vanishing_scoped_action", %{}, %{
               active_app: :vanishing_app,
               registry: [app: [server: registry], actions_overlay: overlay]
             })

    assert response.status == :denied
    assert response.error == {:app_scope_denied, :unregistered_app}
  end
end
