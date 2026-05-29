defmodule AllbertAssist.Objectives.StageTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Objectives.Stage

  test "exposes stable stage vocabulary and persisted names" do
    assert :frame_objective in Stage.stages()
    assert :propose_steps in Stage.stages()
    assert :continue_objective in Stage.stages()

    assert {:ok, "frame_objective"} = Stage.normalize(:frame_objective)
    assert {:ok, "execute_step"} = Stage.normalize("execute_step")
    assert {:error, {:unknown_stage, "future_stage"}} = Stage.normalize("future_stage")
  end
end
