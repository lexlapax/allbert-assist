defmodule AllbertAssist.Jobs.SchedulerAgentTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Jobs.Scheduler
  alias AllbertAssist.Jobs.Scheduler.Agent, as: SchedulerAgent
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Trace

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-scheduler-agent-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "disabled scheduler summary is preserved" do
    scheduler = start_test_scheduler(enabled?: false)

    assert {:ok,
            %{policy: "disabled", claimed: 0, completed: 0, needs_confirmation: 0, failed: 0}} =
             Scheduler.run_once(scheduler, ~U[2026-05-14 08:00:00Z])
  end

  test "startup stale-run cleanup is preserved" do
    now = ~U[2026-05-14 08:00:00Z]

    assert {:ok, job} =
             Jobs.create_job(%{
               name: "stale agent run",
               target_type: "runtime_prompt",
               target: %{text: "Stale."},
               schedule: %{kind: "manual"},
               user_id: "alice"
             })

    assert {:ok, run} =
             Jobs.create_run(job, %{
               trigger: "scheduler",
               status: "running",
               started_at: DateTime.add(now, -600, :second)
             })

    _scheduler =
      start_test_scheduler(
        enabled?: false,
        cleanup_on_start?: true,
        stale_run_ms: 5 * 60 * 1_000
      )

    assert %Run{status: "failed", finished_at: %DateTime{}} = AllbertAssist.Repo.reload!(run)
  end

  test "run_once claims due jobs through the JidoBacked agent" do
    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        {:ok,
         %{
           message: "Agent scheduled response: #{request.text}",
           status: :completed,
           actions: [%{name: "direct_answer", status: :completed}]
         }}
      end
    )

    now = ~U[2026-05-14 08:00:00Z]

    assert {:ok, job} =
             Jobs.create_job(%{
               name: "agent due job",
               target_type: "runtime_prompt",
               target: %{text: "Run when due."},
               schedule: %{kind: "daily", at: "08:00"},
               timezone: "UTC",
               status: "active",
               user_id: "alice"
             })

    assert {:ok, due_job} =
             job
             |> Job.changeset(%{next_due_at: DateTime.add(now, -60, :second)})
             |> Repo.update()

    scheduler = start_test_scheduler(cleanup_on_start?: false)

    assert {:ok, %{policy: "operator_approved", claimed: 1, completed: 1}} =
             Scheduler.run_once(scheduler, now)

    assert [%Run{status: "completed", trigger: "scheduler"}] = Jobs.list_runs(due_job)
  end

  test "private scheduler command modules are not registered capability actions" do
    for module <- SchedulerAgent.command_modules() do
      refute Registry.registered_module?(module)
      assert {:error, {:unknown_action, ^module}} = Registry.capability(module)
    end
  end

  defp start_test_scheduler(opts) do
    name = :"allbert_jobs_scheduler_agent_#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      enabled?: true,
      poll_on_start?: false,
      cleanup_on_start?: false,
      interval_ms: 60_000
    ]

    start_supervised!({Scheduler, Keyword.merge(defaults, opts)})
  end

  defp restore_env(_module, nil), do: :ok
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
