defmodule AllbertAssist.Objectives.DelegateCancelTest do
  use AllbertAssist.DataCase, async: false

  import Ecto.Query

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Execution.ProcessOwner
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Lifecycle
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Objectives.Runs.Cancel
  alias AllbertAssist.Objectives.Runs.CancelToken
  alias AllbertAssist.Repo
  alias AllbertAssist.TestSupport.FanoutReportFixture
  alias AllbertAssist.TestSupport.ReadyEffectContext

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

  test "durable cancellation intent is owned and idempotent" do
    assert {:ok, %{children: [child, _sibling]}} = frame()

    assert {:error, :not_found} =
             Objectives.request_cancellation("other-user", child.id, "not owned")

    assert {:ok, requested} =
             Objectives.request_cancellation("cancel-user", child.id, "operator requested")

    assert requested.status == "blocked"
    assert requested.review_reason == "cancellation_requested"

    assert {:ok, duplicate} =
             Objectives.request_cancellation("cancel-user", child.id, "operator requested")

    assert duplicate.id == requested.id

    assert Enum.count(
             Objectives.list_events(child.id),
             &(&1.kind == "run_blocked" and &1.summary == "Objective cancellation requested")
           ) == 1
  end

  test "parent cancellation preserves completed children and cancels active children" do
    assert {:ok, %{parent: parent, children: [completed, active]}} = frame()

    FanoutReportFixture.complete_child!(completed, "finished before parent cancellation")

    assert {:ok, response} =
             Runner.run(
               "cancel_objective_run",
               %{objective_id: parent.id, reason: "stop remaining work"},
               %{user_id: "cancel-user", channel: "test"}
             )

    assert response.status == :cancelled
    assert {:ok, %{status: "completed"}} = Objectives.get_objective(completed.id)
    assert {:ok, %{status: "cancelled"}} = Objectives.get_objective(active.id)

    assert {:ok,
            %{
              status: "completed",
              join_outcome: "partial",
              report_composition_state: "queued",
              report_delivery_state: "not_ready"
            }} = Objectives.get_objective(parent.id)

    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "joined cancellation is idempotent and inconsistent cancellation fails closed" do
    assert {:ok, %{parent: joined_parent, children: joined_children}} = frame()

    Enum.each(joined_children, fn child ->
      FanoutReportFixture.complete_child!(child, "joined child result")
    end)

    assert {:ok, finalizing} =
             Runner.run(
               "cancel_objective_run",
               %{objective_id: joined_parent.id, reason: "late cancel"},
               %{user_id: "cancel-user", channel: "test"}
             )

    assert finalizing.status == :finalizing
    assert Fanout.parent_projection(joined_parent).phase == :recovering

    select_fallback!(joined_parent)

    assert {:ok, already_finished} =
             Runner.run(
               "cancel_objective_run",
               %{objective_id: joined_parent.id, reason: "late cancel after report selection"},
               %{user_id: "cancel-user", channel: "test"}
             )

    assert already_finished.status == :already_finished

    assert Enum.count(Objectives.list_events(joined_parent.id), &(&1.kind == "fanout_joined")) ==
             1

    assert {:ok, %{parent: corrupt_parent, children: corrupt_children}} = frame()

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^corrupt_parent.id)
             |> Repo.update_all(
               set: [
                 status: "completed",
                 join_outcome: "success",
                 report_delivery_state: "pending",
                 completed_at: DateTime.utc_now()
               ]
             )

    assert Fanout.parent_projection(corrupt_parent).phase == :inconsistent

    assert {:ok, refused} =
             Runner.run(
               "cancel_objective_run",
               %{objective_id: corrupt_parent.id, reason: "must fail closed"},
               %{user_id: "cancel-user", channel: "test"}
             )

    assert refused.status == :error
    assert refused.error == :fanout_state_inconsistent

    assert Enum.all?(corrupt_children, fn child ->
             match?({:ok, %{status: "open"}}, Objectives.get_objective(child.id))
           end)

    assert Enum.all?(corrupt_children, &(Objectives.list_events(&1.id) == []))
  end

  test "generic cancel_objective delegates fan-out parents to the fan-out cancellation action" do
    assert {:ok, %{parent: parent, children: children}} = frame()

    assert {:ok, response} =
             Runner.run(
               "cancel_objective",
               %{objective_id: parent.id, reason: "delegate this cancellation"},
               %{user_id: "cancel-user", channel: "test"}
             )

    assert response.status == :cancelled

    assert Enum.all?(children, fn child ->
             match?({:ok, %{status: "cancelled"}}, Objectives.get_objective(child.id))
           end)
  end

  test "parent cancellation converges when a child completes during the cancellation boundary" do
    for _iteration <- 1..8 do
      assert {:ok, %{parent: parent, children: [racing, _sibling]}} = frame()

      completion =
        Task.async(fn ->
          receive do: (:go -> :ok)

          FanoutReportFixture.complete_child!(racing, "won the cancellation race")
        end)

      cancellation =
        Task.async(fn ->
          receive do: (:go -> :ok)

          Runner.run(
            "cancel_objective_run",
            %{objective_id: parent.id, reason: "race cancellation"},
            %{user_id: "cancel-user", channel: "test"}
          )
        end)

      send(completion.pid, :go)
      send(cancellation.pid, :go)
      _completion_result = Task.await(completion, 2_000)
      assert {:ok, response} = Task.await(cancellation, 2_000)
      assert response.status in [:cancelled, :already_finished]

      eventually(fn -> Fanout.parent_projection(parent).phase == :recovering end)
      select_fallback!(parent)
      eventually(fn -> Fanout.parent_projection(parent).phase == :joined end)

      assert Enum.all?(Fanout.children(parent), fn child ->
               child.status in ~w[completed cancelled failed abandoned] and
                 child.review_reason != "cancellation_requested"
             end)

      assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
    end
  end

  defp frame do
    Fanout.frame(
      ReadyEffectContext.attach(%{
        user_id: "cancel-user",
        title: "cancel",
        objective: "cancel",
        source_channel: "test",
        source_surface: "test",
        source_thread_id: "cancel-thread"
      }),
      ["first", "second"]
    )
  end

  # v1.3 M9.b.12.b. This hand-rolled `%{fallback_reason: "model_disabled"}` as
  # provenance, which carries no layout version, so selection failed
  # `:fanout_report_layout_generation_mismatch` once layout v2 landed. The shared
  # fixture builds provenance through `Report.fallback_provenance/2`.
  defp select_fallback!(parent), do: FanoutReportFixture.select_pending!(parent.id, :fallback)

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
