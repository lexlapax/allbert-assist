defmodule AllbertAssist.Jobs.SchedulerGoldenTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Jobs.Scheduler
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Trace

  @fixture_root Path.expand("../../fixtures/v0.23/jobs", __DIR__)

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-scheduler-golden-#{System.unique_integer([:positive])}"
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

  test "disabled scheduler summary matches the v0.23 fixture" do
    scheduler = start_test_scheduler(enabled?: false)

    assert {:ok, summary} = Scheduler.run_once(scheduler, now())
    assert snapshot(summary) == fixture("disabled_summary.inspect")
  end

  test "paused schedule policy summary matches the v0.23 fixture" do
    assert {:ok, _setting} = Settings.put("jobs.schedule_policy", "paused", %{audit?: false})
    scheduler = start_test_scheduler()

    assert {:ok, summary} = Scheduler.run_once(scheduler, now())
    assert snapshot(summary) == fixture("paused_policy_summary.inspect")
  end

  test "operator-approved no-due summary matches the v0.23 fixture" do
    scheduler = start_test_scheduler()

    assert {:ok, summary} = Scheduler.run_once(scheduler, now())
    assert snapshot(summary) == fixture("operator_approved_no_due_summary.inspect")
  end

  test "completed runtime-prompt run summary matches the v0.23 fixture" do
    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        {:ok,
         %{
           message: "Golden response: #{request.text}",
           status: :completed,
           actions: [%{name: "direct_answer", status: :completed}]
         }}
      end
    )

    assert {:ok, due_job} = create_due_runtime_job("golden completed", "Run golden.")
    scheduler = start_test_scheduler(cleanup_on_start?: false)

    assert {:ok, summary} = Scheduler.run_once(scheduler, now())
    assert snapshot(summary) == fixture("completed_run_summary.inspect")
    assert [%Run{status: "completed", trigger: "scheduler"}] = Jobs.list_runs(due_job)
  end

  test "open running job is skipped without duplicate claim and matches fixture" do
    assert {:ok, due_job} = create_due_runtime_job("golden skipped", "Already running.")

    assert {:ok, _open_run} =
             Jobs.create_run(due_job, %{
               trigger: "scheduler",
               status: "running",
               started_at: DateTime.add(now(), -30, :second)
             })

    scheduler = start_test_scheduler(cleanup_on_start?: false)

    assert {:ok, summary} = Scheduler.run_once(scheduler, now())
    assert snapshot(summary) == fixture("skipped_open_run_summary.inspect")
    assert [%Run{status: "running"}] = Jobs.list_runs(due_job)
  end

  defp create_due_runtime_job(name, text) do
    with {:ok, job} <-
           Jobs.create_job(%{
             name: name,
             target_type: "runtime_prompt",
             target: %{text: text},
             schedule: %{kind: "daily", at: "08:00"},
             timezone: "UTC",
             status: "active",
             user_id: "alice"
           }) do
      job
      |> Job.changeset(%{next_due_at: DateTime.add(now(), -60, :second)})
      |> Repo.update()
    end
  end

  defp start_test_scheduler(opts \\ []) do
    name = :"allbert_jobs_scheduler_golden_#{System.unique_integer([:positive])}"

    scheduler_opts =
      Keyword.merge(
        [
          name: name,
          enabled?: true,
          poll_on_start?: false,
          cleanup_on_start?: false,
          interval_ms: 60_000
        ],
        opts
      )

    start_supervised!(%{
      id: name,
      start: {Scheduler, :start_link, [scheduler_opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    })
  end

  defp snapshot(summary) when is_map(summary) do
    [
      "policy: #{Map.fetch!(summary, :policy)}",
      "claimed: #{Map.fetch!(summary, :claimed)}",
      "completed: #{Map.fetch!(summary, :completed)}",
      "needs_confirmation: #{Map.fetch!(summary, :needs_confirmation)}",
      "failed: #{Map.fetch!(summary, :failed)}",
      "skipped: #{Map.fetch!(summary, :skipped)}"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp fixture(name) do
    @fixture_root
    |> Path.join(name)
    |> File.read!()
  end

  defp now, do: ~U[2026-05-14 08:00:00Z]

  defp restore_env(_module, nil), do: :ok
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
