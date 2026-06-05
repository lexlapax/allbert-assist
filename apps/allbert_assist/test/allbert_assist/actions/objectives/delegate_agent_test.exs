defmodule AllbertAssist.Actions.Objectives.DelegateAgentTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Objectives.AgentRegistry

  defmodule EchoCommand do
    use Jido.Action,
      name: "objective_delegate_echo",
      description: "Delegate action wrapper test command."

    @impl true
    def run(params, context) do
      state = Map.get(context, :state, %{})

      {:ok,
       Map.merge(state, %{
         last_command: :execute,
         last_result:
           {:ok,
            %{
              status: :completed,
              payload: params,
              user_id: Map.get(context, :user_id)
            }}
       })}
    end
  end

  defmodule ResearchCommand do
    use Jido.Action,
      name: "objective_delegate_research",
      description: "Delegate action wrapper research command."

    @impl true
    def run(params, context) do
      state = Map.get(context, :state, %{})

      {:ok,
       Map.merge(state, %{
         last_command: :research,
         last_result:
           {:ok,
            %{
              status: :ok,
              payload: params,
              user_id: Map.get(context, :user_id)
            }}
       })}
    end
  end

  defmodule EchoAgent do
    use AllbertAssist.JidoBacked,
      name: "objective_delegate_echo_agent",
      description: "Delegate action wrapper test agent.",
      signal_routes: [
        {"allbert.objectives.delegate.execute",
         AllbertAssist.Actions.Objectives.DelegateAgentTest.EchoCommand},
        {"allbert.objectives.delegate.research",
         AllbertAssist.Actions.Objectives.DelegateAgentTest.ResearchCommand}
      ]

    @impl true
    def rebuild_state(_opts), do: {:ok, %{last_command: nil, last_result: nil}}

    @impl true
    def command_modules do
      [
        AllbertAssist.Actions.Objectives.DelegateAgentTest.EchoCommand,
        AllbertAssist.Actions.Objectives.DelegateAgentTest.ResearchCommand
      ]
    end
  end

  test "delegate_agent dispatches through the runner and registered objective agent" do
    id = register_echo_agent()

    assert {:ok, response} =
             Runner.run(
               "delegate_agent",
               %{
                 user_id: "alice",
                 objective_id: "obj_1",
                 step_id: "step_1",
                 delegate_agent_id: id,
                 params: %{message: "hello"}
               },
               %{user_id: "alice", operator_id: "alice"}
             )

    assert response.status == :completed
    assert response.delegate_result.agent_id == id
    assert response.delegate_result.state.last_command == :execute
    assert {:ok, result} = response.delegate_result.state.last_result
    assert result.status == :completed
    assert result.payload == %{message: "hello"}

    assert [
             %{
               status: :completed,
               permission: :objective_write,
               delegate_agent_id: ^id,
               objective_id: "obj_1",
               step_id: "step_1",
               command: :execute
             }
           ] = response.actions

    assert response.runner_metadata.action_capability.permission == :objective_write
  end

  test "delegate_agent returns bounded action error when the agent is missing" do
    missing = "missing-#{System.unique_integer([:positive])}"

    assert {:ok, response} =
             Runner.run(
               "delegate_agent",
               %{
                 user_id: "alice",
                 objective_id: "obj_1",
                 step_id: "step_1",
                 delegate_agent_id: missing,
                 params: %{}
               },
               %{user_id: "alice", operator_id: "alice"}
             )

    assert response.status == :error
    assert response.error == :not_found
    assert [%{status: :error, error: :not_found}] = response.actions
  end

  test "delegate_agent validates command names before dispatch" do
    id = register_echo_agent()

    assert {:ok, response} =
             Runner.run(
               "delegate_agent",
               %{
                 user_id: "alice",
                 objective_id: "obj_1",
                 step_id: "step_1",
                 delegate_agent_id: id,
                 command: "not_allowed",
                 params: %{}
               },
               %{user_id: "alice", operator_id: "alice"}
             )

    assert response.status == :error
    assert response.error == :invalid_delegate_command
  end

  test "delegate_agent allows registered metadata commands as strings or atoms" do
    id = register_echo_agent(%{allowed_commands: [:research]})

    for command <- ["research", :research] do
      assert {:ok, response} =
               Runner.run(
                 "delegate_agent",
                 %{
                   user_id: "alice",
                   objective_id: "obj_1",
                   step_id: "step_1",
                   delegate_agent_id: id,
                   command: command,
                   params: %{topic: "delegation"}
                 },
                 %{user_id: "alice", operator_id: "alice"}
               )

      assert response.status == :completed
      assert response.delegate_response.status == :ok
      assert response.delegate_result.state.last_command == :research
      assert {:ok, result} = response.delegate_result.state.last_result
      assert result.payload == %{topic: "delegation"}
      assert [%{command: :research}] = response.actions
    end
  end

  test "delegate_agent rejects pre-atomized commands outside metadata" do
    id = register_echo_agent(%{allowed_commands: [:research]})

    assert {:ok, response} =
             Runner.run(
               "delegate_agent",
               %{
                 user_id: "alice",
                 objective_id: "obj_1",
                 step_id: "step_1",
                 delegate_agent_id: id,
                 command: :not_allowed,
                 params: %{}
               },
               %{user_id: "alice", operator_id: "alice"}
             )

    assert response.status == :error
    assert response.error == :invalid_delegate_command
  end

  test "delegate_agent sees dead registry entries as not found" do
    server = :"objective_delegate_dead_#{System.unique_integer([:positive])}"
    id = "delegate-dead-#{System.unique_integer([:positive])}"
    pid = start_supervised!({EchoAgent, name: server})
    ref = Process.monitor(pid)

    assert {:ok, _entry} = AgentRegistry.register(id, server, EchoAgent, %{})

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    assert {:ok, response} =
             Runner.run(
               "delegate_agent",
               %{
                 user_id: "alice",
                 objective_id: "obj_1",
                 step_id: "step_1",
                 delegate_agent_id: id,
                 params: %{}
               },
               %{user_id: "alice", operator_id: "alice"}
             )

    assert response.status == :error
    assert response.error == :not_found
  end

  defp register_echo_agent(metadata \\ %{}) do
    server = :"objective_delegate_echo_#{System.unique_integer([:positive])}"
    id = "delegate-echo-#{System.unique_integer([:positive])}"

    start_supervised!({EchoAgent, name: server})

    assert {:ok, _entry} =
             AgentRegistry.register(id, server, EchoAgent, Map.put(metadata, :kind, :test))

    on_exit(fn -> AgentRegistry.unregister(id) end)

    id
  end
end
