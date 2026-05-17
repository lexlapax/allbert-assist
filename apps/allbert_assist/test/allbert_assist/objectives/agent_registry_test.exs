defmodule AllbertAssist.Objectives.AgentRegistryTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Objectives.AgentRegistry

  defmodule PingCommand do
    use Jido.Action,
      name: "objective_registry_ping",
      description: "Registry dispatch test command."

    @impl true
    def run(params, context) do
      state = Map.get(context, :state, %{})

      {:ok,
       Map.merge(state, %{
         last_command: :ping,
         last_result: {:ok, %{reply: Map.get(params, :message) || Map.get(params, "message")}}
       })}
    end
  end

  defmodule StubAgent do
    use AllbertAssist.JidoBacked,
      name: "objective_registry_stub",
      description: "Registry dispatch test agent.",
      signal_routes: [
        {"allbert.objectives.delegate.ping",
         AllbertAssist.Objectives.AgentRegistryTest.PingCommand}
      ]

    @impl true
    def rebuild_state(_opts), do: {:ok, %{last_command: nil, last_result: nil}}

    @impl true
    def command_modules, do: [AllbertAssist.Objectives.AgentRegistryTest.PingCommand]
  end

  test "register, lookup, dispatch, and unregister round-trip" do
    server = :"objective_registry_stub_#{System.unique_integer([:positive])}"
    id = "stub-#{System.unique_integer([:positive])}"

    start_supervised!({StubAgent, name: server})

    assert {:ok, entry} = AgentRegistry.register(id, server, StubAgent, %{kind: :test})
    assert entry.id == id
    assert {:error, :already_registered} = AgentRegistry.register(id, server, StubAgent)
    assert {:ok, %{id: ^id, module: StubAgent}} = AgentRegistry.lookup(id)

    assert {:ok, %{agent_id: ^id, state: state}} =
             AgentRegistry.dispatch(id, :ping, %{message: "pong"})

    assert state.last_result == {:ok, %{reply: "pong"}}

    assert :ok = AgentRegistry.unregister(id)
    assert {:error, :not_found} = AgentRegistry.lookup(id)
  end

  test "missing lookup and dispatch return not_found" do
    id = "missing-#{System.unique_integer([:positive])}"

    assert {:error, :not_found} = AgentRegistry.lookup(id)
    assert {:error, :not_found} = AgentRegistry.dispatch(id, :ping, %{})
  end
end
