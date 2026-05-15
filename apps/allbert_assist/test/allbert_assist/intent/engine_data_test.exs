defmodule AllbertAssist.Intent.EngineDataTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Intent.Engine
  alias AllbertAssist.Intent.EvalFixtures
  alias AllbertAssist.Jobs

  test "collects user-scoped scheduled job candidates" do
    assert {:ok, job} =
             Jobs.create_job(%{
               name: "market open brief",
               target_type: "runtime_prompt",
               target: %{text: "Summarize the market open."},
               schedule: %{kind: "manual"},
               user_id: "alice"
             })

    candidates =
      Engine.collect_candidates(
        EvalFixtures.request(text: "show my scheduled jobs", user_id: "alice")
      )

    assert Enum.any?(candidates, fn candidate ->
             candidate.kind == :job and
               candidate.job_id == job.id and
               candidate.trace_metadata.target_type == "runtime_prompt"
           end)
  end
end
