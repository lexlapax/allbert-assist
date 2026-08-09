defmodule AllbertAssist.Objectives.FanoutSteeringTest.EpochSteering do
  @moduledoc false

  alias AllbertAssist.Objectives.Steering
  alias AllbertAssist.TestSupport.ReadyEffectContext

  def steer(user_id, objective_id, directive) do
    Steering.steer(user_id, objective_id, directive, ReadyEffectContext.context())
  end

  def apply_pending(objective_id) do
    Steering.apply_pending(objective_id, ReadyEffectContext.context())
  end
end

defmodule AllbertAssist.Objectives.FanoutSteeringTest.EpochTransitions do
  @moduledoc false

  alias AllbertAssist.Objectives.Fanout.TerminalTransitions
  alias AllbertAssist.TestSupport.ReadyEffectContext

  def terminalize_child(child, attrs, kind, payload, opts \\ []) do
    TerminalTransitions.terminalize_child(
      child,
      attrs,
      kind,
      payload,
      Keyword.put_new(opts, :effect_context, ReadyEffectContext.context())
    )
  end
end

defmodule AllbertAssist.Objectives.FanoutSteeringTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.FanoutSteeringTest.EpochTransitions, as: TerminalTransitions
  alias AllbertAssist.Objectives.FanoutSteeringTest.EpochSteering, as: Steering
  alias AllbertAssist.TestSupport.FanoutReportFixture

  test "directive is ownership-bound, durable, idempotent, and applied at a boundary" do
    {:ok, %{children: [child | _]}} =
      frame(%{user_id: "alice", title: "Work", objective: "Work"}, ["One", "Two"])

    assert {:error, :not_found} = Steering.steer("mallory", child.id, "Do something else")

    assert {:ok, %{directive_event: directive}} =
             Steering.steer("alice", child.id, "Use primary sources")

    assert {:ok, updated} = Steering.apply_pending(child.id)
    assert updated.objective == "Use primary sources"

    assert Enum.map(Objectives.list_events(child.id), & &1.kind) == [
             "steer_applied",
             "steer_directive"
           ]

    assert {:ok, _} = Steering.apply_pending(child.id)
    assert Enum.count(Objectives.list_events(child.id), &(&1.kind == "steer_applied")) == 1
    assert is_binary(directive.id)
  end

  test "terminal objectives reject steering" do
    {:ok, objective} =
      create_objective(%{
        user_id: "alice",
        title: "Done",
        objective: "Done",
        status: "completed"
      })

    assert {:error, :not_fanout_child} = Steering.steer("alice", objective.id, "Again")
    refute Enum.any?(Objectives.list_events(objective.id), &(&1.kind == "steer_directive"))
  end

  test "parents and ordinary active objectives reject fan-out steering without recording directives" do
    {:ok, %{parent: parent}} =
      frame(%{user_id: "alice", title: "Parent", objective: "Parent"}, ["One", "Two"])

    {:ok, ordinary} =
      create_objective(%{user_id: "alice", title: "Ordinary", objective: "Ordinary"})

    assert {:error, :not_fanout_child} = Steering.steer("alice", parent.id, "Change parent")
    assert {:error, :not_fanout_child} = Steering.steer("alice", ordinary.id, "Change ordinary")

    refute Enum.any?(Objectives.list_events(parent.id), &(&1.kind == "steer_directive"))
    refute Enum.any?(Objectives.list_events(ordinary.id), &(&1.kind == "steer_directive"))
  end

  defp create_objective(attrs) do
    Objectives.create_objective(attrs, AllbertAssist.TestSupport.ReadyEffectContext.context())
  end

  defp frame(parent_attrs, tasks) do
    Fanout.frame(
      Map.merge(parent_attrs, AllbertAssist.TestSupport.ReadyEffectContext.context()),
      tasks
    )
  end

  test "terminal fan-in identifies the effective steered child and its result" do
    {:ok, %{parent: parent, children: [child | _]}} =
      frame(%{user_id: "alice", title: "Work", objective: "Work"}, ["One", "Two"])

    assert {:ok, _steer} =
             Steering.steer("alice", child.id, "Explain OTP supervision as a restaurant analogy")

    assert {:ok, steered} = Steering.apply_pending(child.id)

    FanoutReportFixture.complete_child!(steered, "The supervisor is the restaurant manager.")

    [_steered_child, other] = Fanout.children(parent)

    FanoutReportFixture.complete_child!(other, "Second result")

    report = Fanout.report(parent)
    [steered_report | _] = report.children

    assert steered_report.title == "Explain OTP supervision as a restaurant analogy"
    assert steered_report.result_summary == "The supervisor is the restaurant manager."
  end

  test "completion cannot consume a directive that was durably queued first" do
    {:ok, %{children: [child | _]}} =
      frame(%{user_id: "alice", title: "Race", objective: "Race"}, ["One", "Two"])

    assert {:ok, _queued} = Steering.steer("alice", child.id, "Use the steered objective")

    assert {:error, :pending_steering_directive} =
             TerminalTransitions.terminalize_child(
               child,
               %{status: "completed", completed_at: DateTime.utc_now()},
               "run_completed",
               %{},
               effect_context: AllbertAssist.TestSupport.ReadyEffectContext.context()
             )

    assert {:ok, steered} = Steering.apply_pending(child.id)
    assert steered.objective == "Use the steered objective"

    assert {:ok, %{child: %{status: "completed"}}} =
             TerminalTransitions.terminalize_child(
               steered,
               %{status: "completed", completed_at: DateTime.utc_now()},
               "run_completed",
               %{},
               effect_context: AllbertAssist.TestSupport.ReadyEffectContext.context()
             )
  end

  test "a directive arriving after completion is honestly rejected" do
    {:ok, %{children: [child | _]}} =
      frame(%{user_id: "alice", title: "Race", objective: "Race"}, ["One", "Two"])

    assert {:ok, %{child: completed}} =
             TerminalTransitions.terminalize_child(
               child,
               %{status: "completed", completed_at: DateTime.utc_now()},
               "run_completed",
               %{},
               effect_context: AllbertAssist.TestSupport.ReadyEffectContext.context()
             )

    assert completed.status == "completed"
    assert {:error, :terminal} = Steering.steer("alice", child.id, "Too late")
    refute Enum.any?(Objectives.list_events(child.id), &(&1.kind == "steer_directive"))
  end

  test "concurrent completion and steering serialize without an orphan directive" do
    for iteration <- 1..12 do
      {:ok, %{children: [child | _]}} =
        frame(
          %{user_id: "alice", title: "Race #{iteration}", objective: "Race"},
          ["One", "Two"]
        )

      completion =
        Task.async(fn ->
          receive do: (:go -> :ok)

          TerminalTransitions.terminalize_child(
            child,
            %{status: "completed", completed_at: DateTime.utc_now()},
            "run_completed",
            %{},
            effect_context: AllbertAssist.TestSupport.ReadyEffectContext.context()
          )
        end)

      steering =
        Task.async(fn ->
          receive do: (:go -> :ok)
          Steering.steer("alice", child.id, "Steered #{iteration}")
        end)

      send(completion.pid, :go)
      send(steering.pid, :go)
      completion_result = Task.await(completion, 2_000)
      steering_result = Task.await(steering, 2_000)

      case steering_result do
        {:ok, _steer} ->
          assert completion_result == {:error, :pending_steering_directive}
          assert {:ok, steered} = Steering.apply_pending(child.id)

          assert {:ok, %{child: %{status: "completed"}}} =
                   TerminalTransitions.terminalize_child(
                     steered,
                     %{status: "completed", completed_at: DateTime.utc_now()},
                     "run_completed",
                     %{},
                     effect_context: AllbertAssist.TestSupport.ReadyEffectContext.context()
                   )

        {:error, :terminal} ->
          assert match?({:ok, %{child: %{status: "completed"}}}, completion_result)
      end

      events = Objectives.list_events(child.id)
      directives = Enum.filter(events, &(&1.kind == "steer_directive"))
      applied = Enum.filter(events, &(&1.kind == "steer_applied"))
      assert length(directives) == length(applied)
    end
  end
end
