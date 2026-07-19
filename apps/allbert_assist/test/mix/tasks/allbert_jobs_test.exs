defmodule Mix.Tasks.Allbert.JobsTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Trace
  alias Mix.Tasks.Allbert.Jobs, as: JobsTask

  setup do
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-jobs-task-test-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Memory, root: Path.join(root, "memory"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        {:ok,
         %{
           message: "Task runtime response: #{request.text}",
           status: :completed,
           actions: [%{name: "direct_answer", status: :completed}]
         }}
      end
    )

    on_exit(fn ->
      restore_env(Memory, original_memory_config)
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      Mix.Task.reenable("allbert.jobs")
      File.rm_rf!(root)
    end)

    :ok
  end

  test "creates, lists, shows, pauses, and resumes runtime prompt jobs" do
    create_output =
      capture_io(fn ->
        assert :ok =
                 JobsTask.run([
                   "create",
                   "runtime-prompt",
                   "daily-brief",
                   "--user",
                   "alice",
                   "--prompt",
                   "Brief me.",
                   "--manual"
                 ])
      end)

    assert create_output =~ "Created job_"
    assert [%{id: job_id}] = Jobs.list_jobs("alice")

    list_output =
      capture_io(fn ->
        assert :ok = JobsTask.run(["list", "--user", "alice"])
      end)

    assert list_output =~ job_id
    assert list_output =~ "status=paused"
    assert list_output =~ "schedule=manual"
    assert list_output =~ "thread=recent"

    show_output =
      capture_io(fn ->
        assert :ok = JobsTask.run(["show", job_id])
      end)

    assert show_output =~ "Job: #{job_id}"
    assert show_output =~ "Target: runtime_prompt"
    assert show_output =~ "User: alice"

    pause_output =
      capture_io(fn ->
        assert :ok = JobsTask.run(["pause", job_id])
      end)

    assert pause_output =~ "status=paused"

    resume_output =
      capture_io(fn ->
        assert :ok = JobsTask.run(["resume", job_id])
      end)

    assert resume_output =~ "status=active"
  end

  test "runs runtime prompt jobs and lists run history" do
    capture_io(fn ->
      assert :ok =
               JobsTask.run([
                 "create",
                 "runtime-prompt",
                 "run-me",
                 "--user",
                 "alice",
                 "--prompt",
                 "Run from CLI.",
                 "--new-thread-per-run"
               ])
    end)

    assert [%{id: job_id}] = Jobs.list_jobs("alice")

    run_output =
      capture_io(fn ->
        assert :ok = JobsTask.run(["run", job_id])
      end)

    assert run_output =~ "status=completed"
    assert run_output =~ "Task runtime response: Run from CLI."

    runs_output =
      capture_io(fn ->
        assert :ok = JobsTask.run(["runs", job_id])
      end)

    assert runs_output =~ "trigger=manual"
    assert runs_output =~ "status=completed"
  end

  test "lists templates and creates registered-action template jobs" do
    templates_output =
      capture_io(fn ->
        assert :ok = JobsTask.run(["templates"])
      end)

    assert templates_output =~ "daily-brief"
    assert templates_output =~ "registry-health"
    assert templates_output =~ "trace-summary"
    assert templates_output =~ "memory-index-rebuild"

    create_output =
      capture_io(fn ->
        assert :ok =
                 JobsTask.run([
                   "create",
                   "template",
                   "registry-health",
                   "--user",
                   "alice",
                   "--manual"
                 ])
      end)

    assert create_output =~ "Created job_"

    assert [%{id: job_id, target_type: "registered_action", metadata: metadata}] =
             Jobs.list_jobs("alice")

    assert metadata == %{"template_name" => "registry-health"} or
             metadata == %{template_name: "registry-health"}

    run_output =
      capture_io(fn ->
        assert :ok = JobsTask.run(["run", job_id])
      end)

    assert run_output =~ "status=completed"
    assert run_output =~ "Registry health:"
  end

  test "rejects conflicting identity and invalid list status" do
    assert_raise Mix.Error, ~r/--user and --operator must match/, fn ->
      JobsTask.run([
        "create",
        "runtime-prompt",
        "conflict",
        "--user",
        "alice",
        "--operator",
        "bob",
        "--prompt",
        "Nope"
      ])
    end

    assert_raise Mix.Error, ~r/--status must be one of/, fn ->
      JobsTask.run(["list", "--status", "archived"])
    end
  end

  test "surfaces blocked confirmation ids for resume and manual run commands" do
    assert {:ok, confirmation} = create_pending_confirmation("conf_cli_blocked_job")

    assert {:ok, job} =
             Jobs.create_job(%{
               name: "blocked cli job",
               target_type: "runtime_prompt",
               target: %{text: "Fetch https://example.com"},
               schedule: %{kind: "manual"},
               user_id: "alice"
             })

    assert {:ok, blocked_job} =
             job
             |> Job.changeset(%{
               status: "blocked",
               blocked_confirmation_id: confirmation["id"],
               next_due_at: nil
             })
             |> Repo.update()

    assert_raise Mix.Error, ~r/mix allbert.confirmations show conf_cli_blocked_job/, fn ->
      capture_io(fn -> JobsTask.run(["resume", blocked_job.id]) end)
    end

    assert_raise Mix.Error, ~r/mix allbert.confirmations show conf_cli_blocked_job/, fn ->
      capture_io(fn -> JobsTask.run(["run", blocked_job.id]) end)
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp create_pending_confirmation(id) do
    Confirmations.create(%{
      id: id,
      origin: %{
        actor: "alice",
        channel: :job,
        surface: "mix allbert.jobs"
      },
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{url: "https://example.com"},
      resume_params_ref: %{url: "https://example.com"}
    })
  end
end
