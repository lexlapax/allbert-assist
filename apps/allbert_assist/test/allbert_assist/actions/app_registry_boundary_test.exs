defmodule AllbertAssist.Actions.AppRegistryBoundaryTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Actions.Runner

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

    assert {:ok, response} =
             Runner.run("direct_answer", %{answer: "must not execute"}, %{
               active_app: :vanishing_app,
               registry: [app: [server: registry]]
             })

    assert response.status == :denied
    assert response.error == {:app_scope_denied, :unregistered_app}
  end
end
