defmodule AllbertAssist.Intent.CandidateTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Intent.Candidate

  test "builds bounded selected action candidates from registered actions" do
    assert {:ok, candidate} =
             Candidate.new(%{
               kind: :action,
               id: "direct_answer",
               action_name: "direct_answer",
               source: :registry,
               status: :selected,
               selected?: true,
               score: 4.2,
               reason: String.duplicate("safe route ", 80)
             })

    assert candidate.action_name == "direct_answer"
    assert candidate.score == 1.0
    assert candidate.selected?
    assert byte_size(candidate.reason) <= 240
  end

  test "rejects unknown selected action names" do
    assert {:error, {:unknown_action, "invented_action", {:unknown_action, "invented_action"}}} =
             Candidate.new(%{
               kind: :action,
               id: "invented_action",
               action_name: "invented_action",
               source: :model
             })
  end

  test "rejects unknown app ids without creating atoms" do
    refute safe_existing_atom?("invented_v019_app")

    assert {:error, {:unknown_app_id, "invented_v019_app"}} =
             Candidate.new(%{
               kind: :surface,
               id: "surface",
               source: :registry,
               app_id: "invented_v019_app"
             })

    refute safe_existing_atom?("invented_v019_app")
  end

  test "bounds candidates by total and kind limits" do
    candidates =
      for index <- 1..5 do
        Candidate.new!(%{
          kind: :skill,
          id: "skill-#{index}",
          source: :registry,
          status: :candidate,
          score: 0.5
        })
      end

    assert [%{id: "skill-1"}, %{id: "skill-2"}] =
             Candidate.bound(candidates, total_limit: 3, kind_limits: %{skill: 2})
  end

  test "redacts trace metadata" do
    candidate =
      Candidate.new!(%{
        kind: :direct_answer,
        id: "direct",
        source: :deterministic,
        trace_metadata: %{api_key: "secret-value", note: "ok"}
      })

    assert candidate.trace_metadata.note == "ok"
    refute candidate.trace_metadata.api_key == "secret-value"
  end

  test "redacts and normalizes malformed trace metadata list tails" do
    candidate =
      Candidate.new!(%{
        kind: :direct_answer,
        id: "direct",
        source: :deterministic,
        trace_metadata: %{
          values: [%{api_key: "secret-value"} | %{token: "another-secret"}]
        }
      })

    assert [%{} = first, %{} = second] = candidate.trace_metadata.values
    refute first.api_key == "secret-value"
    refute second.token == "another-secret"
  end

  defp safe_existing_atom?(value) do
    _atom = String.to_existing_atom(value)
    true
  rescue
    ArgumentError -> false
  end
end
