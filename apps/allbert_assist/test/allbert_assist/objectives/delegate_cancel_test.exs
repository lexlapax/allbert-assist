defmodule AllbertAssist.Objectives.DelegateCancelTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Execution.ProcessOwner
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Lifecycle
  alias AllbertAssist.Objectives.Runs.Cancel
  alias AllbertAssist.Objectives.Runs.CancelToken

  defmodule CheckpointAdapter do
    def operation(operation, state, opts) do
      if operation == :execute do
        send(Keyword.fetch!(opts, :test_pid), {:execute_started, self()})

        receive do
          :complete_operation -> {:ok, state}
        end
      else
        {:ok, state}
      end
    end
  end

  defmodule UncooperativeRun do
    use GenServer, restart: :temporary

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def child_spec(opts) do
      %{
        id: {__MODULE__, Keyword.fetch!(opts, :child_id)},
        start: {__MODULE__, :start_link, [opts]},
        restart: :temporary
      }
    end

    @impl true
    def init(opts) do
      child_id = Keyword.fetch!(opts, :child_id)
      token = Keyword.fetch!(opts, :cancel_token)

      {:ok, _} =
        Registry.register(AllbertAssist.Objectives.Runs.Registry, {:run, child_id}, token)

      send(Keyword.fetch!(opts, :test_pid), {:uncooperative_started, self()})
      {:ok, %{}}
    end
  end

  test "lifecycle completes the current operation and cancels at the next checkpoint" do
    assert {:ok, %{parent: _parent, children: [child, _sibling]}} = frame()
    token = CancelToken.new()
    parent = self()

    task =
      Task.async(fn ->
        Lifecycle.run(child.id,
          adapter: CheckpointAdapter,
          cancel_token: token,
          test_pid: parent
        )
      end)

    assert_receive {:execute_started, run_pid}, 2_000
    :ok = CancelToken.cancel(token)
    send(run_pid, :complete_operation)

    assert {:ok, %{status: "cancelled"}} = Task.await(task, 2_000)
  end

  test "delegate dispatch rejects an already-cancelled token before contacting an agent" do
    token = CancelToken.new()
    :ok = CancelToken.cancel(token)

    assert {:error, :cancelled} =
             AgentRegistry.dispatch("missing-agent", :execute, %{}, cancel_token: token)
  end

  test "unchecked work escalates to supervised shutdown after the grace window" do
    child_id = "uncooperative-#{System.unique_integer([:positive])}"
    token = CancelToken.new()

    assert {:ok, pid} =
             DynamicSupervisor.start_child(
               AllbertAssist.Objectives.Runs.Supervisor,
               {UncooperativeRun, child_id: child_id, cancel_token: token, test_pid: self()}
             )

    assert_receive {:uncooperative_started, ^pid}
    assert {:ok, :supervised} = Cancel.cancel(child_id, grace_ms: 100)
    refute Process.alive?(pid)
    assert CancelToken.cancelled?(token)
  end

  test "unchecked work with a captured execution reaches OS-kill before supervised shutdown" do
    child_id = "os-tier-#{System.unique_integer([:positive])}"
    token = CancelToken.new()

    assert {:ok, run_pid} =
             DynamicSupervisor.start_child(
               AllbertAssist.Objectives.Runs.Supervisor,
               {UncooperativeRun, child_id: child_id, cancel_token: token, test_pid: self()}
             )

    assert_receive {:uncooperative_started, ^run_pid}

    execution =
      Task.async(fn ->
        ProcessOwner.run("/bin/sleep", ["30"],
          execution_id: child_id,
          cd: "/",
          env: [],
          timeout_ms: 30_000,
          kill_grace_ms: 100,
          max_output_bytes: 100
        )
      end)

    eventually(fn ->
      Registry.lookup(AllbertAssist.Execution.ProcessRegistry, {:execution, child_id}) != []
    end)

    assert {:ok, :os_kill} = Cancel.cancel(child_id, grace_ms: 100)
    assert {:ok, %{exit_status: nil}} = Task.await(execution, 5_000)
    refute Process.alive?(run_pid)
  end

  test "both shipped delegate families declare natural-boundary checkpoints" do
    root = Path.expand("../../../../..", __DIR__)

    for path <- [
          "plugins/allbert.research/lib/allbert_research/commands/research.ex",
          "plugins/allbert.research/lib/allbert_research/commands/summarize_url.ex",
          "plugins/stocksage/lib/stocksage/agents/commands/execute.ex"
        ] do
      assert File.read!(Path.join(root, path)) =~ "CancelToken.checkpoint"
    end
  end

  test "registered cancellation action is ownership-bound and records the tier" do
    assert {:ok, %{parent: parent, children: children}} = frame()

    assert {:ok, denied} =
             Runner.run(
               "cancel_objective_run",
               %{objective_id: parent.id, reason: "stop"},
               %{user_id: "other-user", channel: "test"}
             )

    assert denied.status == :denied

    assert {:ok, cancelled} =
             Runner.run(
               "cancel_objective_run",
               %{objective_id: parent.id, reason: "operator requested"},
               %{user_id: "cancel-user", channel: "test"}
             )

    assert cancelled.status == :cancelled
    assert cancelled.cancellation_tier == :cooperative
    assert {:ok, %{status: "cancelled"}} = Objectives.get_objective(parent.id)

    assert Enum.all?(children, fn child ->
             match?({:ok, %{status: "cancelled"}}, Objectives.get_objective(child.id))
           end)
  end

  defp frame do
    Fanout.frame(
      %{
        user_id: "cancel-user",
        title: "cancel",
        objective: "cancel",
        source_channel: "test",
        source_surface: "test",
        source_thread_id: "cancel-thread"
      },
      ["first", "second"]
    )
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: flunk("condition did not become true")

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
