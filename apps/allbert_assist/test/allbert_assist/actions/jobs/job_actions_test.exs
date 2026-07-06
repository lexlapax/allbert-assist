defmodule AllbertAssist.Actions.Jobs.JobActionsTest do
  @moduledoc """
  v0.61 M10.4 — the registered job actions must scope reads and effects to the
  server-derived context identity, ignoring any params-supplied user id, so a client
  cannot read or mutate another user's jobs through the request body.
  """
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Jobs
  alias AllbertAssist.Repo

  defp create_job(user_id, name) do
    {:ok, job} =
      Jobs.create_job(%{
        name: name,
        target_type: "runtime_prompt",
        target: %{text: "#{name} body"},
        schedule: %{kind: "manual"},
        user_id: user_id
      })

    job
  end

  test "list_jobs is scoped to the context identity, ignoring a spoofed params user_id" do
    local_job = create_job("local", "local job")
    _alice_job = create_job("alice", "alice job")

    # context identity "local" must win over the params "alice".
    assert {:ok, %{status: :completed, jobs: jobs}} =
             Runner.run("list_jobs", %{user_id: "alice"}, %{user_id: "local"})

    ids = Enum.map(jobs, & &1.id)
    assert local_job.id in ids
    refute Enum.any?(jobs, &(&1.user_id == "alice"))
  end

  test "pause_job/run_job/resume_job cannot touch another user's job by crafted id" do
    alice_job = create_job("alice", "alice active")
    original_status = alice_job.status

    for action <- ["pause_job", "resume_job"] do
      assert {:ok, %{status: :error, error: {:job_not_found, _}}} =
               Runner.run(action, %{id: alice_job.id, user_id: "alice"}, %{user_id: "local"})
    end

    assert {:ok, %{status: :error, error: {:job_not_found, _}}} =
             Runner.run("run_job", %{id: alice_job.id, user_id: "alice"}, %{user_id: "local"})

    assert Repo.reload!(alice_job).status == original_status
    assert [] = Jobs.list_runs(alice_job)
  end

  test "pause_job on the operator's own job succeeds through the action boundary" do
    job = create_job("local", "local pausable")

    assert {:ok, %{status: :completed, message: message}} =
             Runner.run("pause_job", %{id: job.id, user_id: "local"}, %{user_id: "local"})

    assert message =~ "Paused"
    assert Repo.reload!(job).status == "paused"
  end

  test "create_job creates a job owned by the context identity" do
    attrs = %{
      name: "created via action",
      target_type: "runtime_prompt",
      target: %{text: "hello"},
      schedule: %{kind: "manual"}
    }

    assert {:ok, %{status: :completed, job: job, message: message}} =
             Runner.run("create_job", %{attrs: attrs}, %{user_id: "local"})

    assert message =~ "Created"
    assert job.user_id == "local"
    assert Enum.any?(Jobs.list_jobs("local"), &(&1.id == job.id))
  end

  test "create_job forces ownership to the server-derived identity over spoofed attrs" do
    attrs = %{
      name: "spoof attempt",
      target_type: "runtime_prompt",
      target: %{text: "hello"},
      schedule: %{kind: "manual"},
      user_id: "alice",
      operator_id: "alice"
    }

    assert {:ok, %{status: :completed, job: job}} =
             Runner.run("create_job", %{attrs: attrs, user_id: "alice"}, %{user_id: "local"})

    assert job.user_id == "local"
    assert job.operator_id == "local"
    assert [] = Jobs.list_jobs("alice")
  end
end
