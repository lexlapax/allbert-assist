defmodule Mix.Tasks.Allbert.DelegateTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Objectives.AgentRegistry
  alias Mix.Tasks.Allbert.Delegate, as: DelegateTask

  defmodule EchoCommand do
    use Jido.Action,
      name: "allbert_delegate_task_echo",
      description: "Delegate task echo command."

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
              summary: "echo #{Map.get(params, "ticker", "none")}",
              payload: params
            }}
       })}
    end
  end

  defmodule EchoAgent do
    use AllbertAssist.JidoBacked,
      name: "allbert_delegate_task_echo_agent",
      description: "Delegate task echo agent.",
      signal_routes: [
        {"allbert.objectives.delegate.execute", Mix.Tasks.Allbert.DelegateTest.EchoCommand}
      ]

    @impl true
    def rebuild_state(_opts), do: {:ok, %{last_command: nil, last_result: nil}}

    @impl true
    def command_modules, do: [Mix.Tasks.Allbert.DelegateTest.EchoCommand]
  end

  setup do
    previous_halt = Application.get_env(:allbert_assist, Mix.Tasks.Allbert.Delegate)

    Application.put_env(:allbert_assist, Mix.Tasks.Allbert.Delegate,
      halt_fun: fn code -> throw({:halt, code}) end
    )

    on_exit(fn ->
      Mix.Task.reenable("allbert.delegate")

      if previous_halt do
        Application.put_env(:allbert_assist, Mix.Tasks.Allbert.Delegate, previous_halt)
      else
        Application.delete_env(:allbert_assist, Mix.Tasks.Allbert.Delegate)
      end
    end)
  end

  test "delegates to a registered objective agent through the action runner" do
    id = register_echo_agent()

    output =
      capture_io(fn ->
        assert :ok =
                 DelegateTask.run([
                   id,
                   ~s({"ticker":"AAPL"}),
                   "--user",
                   "alice"
                 ])
      end)

    assert output =~ "Allbert delegate #{id}"
    assert output =~ "Status: completed"
    assert output =~ "Summary: echo AAPL"
  end

  test "missing agents exit with the documented not-found code" do
    assert {:halt, 65} =
             catch_throw(
               capture_io(:stderr, fn ->
                 DelegateTask.run(["missing-agent", ~s({}), "--user", "alice"])
               end)
             )
  end

  defp register_echo_agent do
    server = :"allbert_delegate_task_echo_#{System.unique_integer([:positive])}"
    id = "delegate-task-#{System.unique_integer([:positive])}"

    start_supervised!({EchoAgent, name: server})
    assert {:ok, _entry} = AgentRegistry.register(id, server, EchoAgent, %{app_id: :allbert})

    on_exit(fn -> AgentRegistry.unregister(id) end)

    id
  end
end
