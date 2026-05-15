defmodule AllbertAssist.JobsTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations
  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Jobs.Runner
  alias AllbertAssist.Jobs.Scheduler
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Runtime
  alias AllbertAssist.Session
  alias AllbertAssist.Settings
  alias AllbertAssist.Trace

  @env_vars ["ALLBERT_HOME", "ALLBERT_HOME_DIR", "ALLBERT_SETTINGS_ROOT"]

  setup do
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Memory)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Runtime)
    Application.delete_env(:allbert_assist, Settings)
    Application.delete_env(:allbert_assist, Trace)

    home = Path.join(System.tmp_dir!(), "allbert-jobs-test-#{System.unique_integer([:positive])}")
    System.put_env("ALLBERT_HOME", home)
    Application.put_env(:allbert_assist, Memory, root: Path.join(home, "memory"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Memory, original_memory_config)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Runtime, original_runtime_config)
      restore_app_env(Settings, original_settings_config)
      restore_app_env(Trace, original_trace_config)
    end)

    :ok
  end

  describe "settings" do
    test "job settings are writable and validated" do
      assert {:ok, timezone} = Settings.put("jobs.timezone", "UTC", %{audit?: false})
      assert timezone.value == "UTC"
      assert timezone.writable?

      assert {:ok, default_state} =
               Settings.put("jobs.default_state", "active", %{audit?: false})

      assert default_state.value == "active"

      assert {:ok, schedule_policy} =
               Settings.put("jobs.schedule_policy", "paused", %{audit?: false})

      assert schedule_policy.value == "paused"

      assert {:error, {:invalid_setting, "jobs.default_state", _reason}} =
               Settings.put("jobs.default_state", "archived", %{})
    end
  end

  describe "jobs" do
    test "creates paused runtime prompt jobs with opaque ids and stored full targets" do
      assert {:ok, %Job{} = job} =
               Jobs.create_job(%{
                 name: "daily brief",
                 target_type: "runtime_prompt",
                 target: %{text: "Summarize my priorities."},
                 schedule: %{kind: "manual"},
                 user_id: "alice"
               })

      assert String.starts_with?(job.id, "job_")
      assert job.user_id == "alice"
      assert job.operator_id == "alice"
      assert job.target == %{"text" => "Summarize my priorities."}
      assert job.schedule == %{"kind" => "manual"}
      assert job.status == "paused"
      assert job.thread_mode == "recent_general"
      assert job.channel == "job"
      assert job.next_due_at == nil
    end

    test "uses Settings Central defaults for timezone and status" do
      assert {:ok, _timezone} = Settings.put("jobs.timezone", "UTC", %{audit?: false})
      assert {:ok, _status} = Settings.put("jobs.default_state", "active", %{audit?: false})

      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "utc brief",
                 target_type: "runtime_prompt",
                 target: %{text: "Summarize."},
                 schedule: %{kind: "daily", at: "08:00"},
                 user_id: "alice"
               })

      assert job.timezone == "UTC"
      assert job.status == "active"
      assert %DateTime{} = job.next_due_at
    end

    test "keeps job names unique per user only" do
      attrs = %{
        name: "same name",
        target_type: "runtime_prompt",
        target: %{text: "Hello"},
        schedule: %{kind: "manual"}
      }

      assert {:ok, _job} = Jobs.create_job(Map.put(attrs, :user_id, "alice"))
      assert {:error, %Ecto.Changeset{}} = Jobs.create_job(Map.put(attrs, :user_id, "alice"))
      assert {:ok, _job} = Jobs.create_job(Map.put(attrs, :user_id, "bob"))
    end

    test "preserves operator alias and fails conflicting user/operator ids" do
      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "operator alias",
                 target_type: "runtime_prompt",
                 target: %{text: "Hello"},
                 schedule: %{kind: "manual"},
                 operator: "alice"
               })

      assert job.user_id == "alice"
      assert job.operator_id == "alice"

      assert {:error, :identity_conflict} =
               Jobs.create_job(%{
                 name: "conflict",
                 target_type: "runtime_prompt",
                 target: %{text: "Hello"},
                 schedule: %{kind: "manual"},
                 user_id: "alice",
                 operator_id: "bob"
               })
    end

    test "validates target contracts" do
      assert {:error, {:invalid_target, :missing_text}} =
               Jobs.create_job(%{
                 name: "missing prompt",
                 target_type: "runtime_prompt",
                 target: %{},
                 schedule: %{kind: "manual"},
                 user_id: "alice"
               })

      assert {:error, {:invalid_target, :missing_params}} =
               Jobs.create_job(%{
                 name: "missing params",
                 target_type: "registered_action",
                 target: %{action_name: "AllbertAssist.Actions.Example"},
                 schedule: %{kind: "manual"},
                 user_id: "alice"
               })
    end

    test "uses recent_general as the neutral registered-action thread mode" do
      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "registry health",
                 target_type: "registered_action",
                 target: %{
                   action_name: "AllbertAssist.Actions.RegistryHealth",
                   params: %{}
                 },
                 schedule: %{kind: "manual"},
                 user_id: "alice",
                 thread_mode: "origin_thread"
               })

      assert job.thread_mode == "recent_general"
    end

    test "validates origin thread ownership for runtime prompt jobs" do
      assert {:ok, thread} = Conversations.create_general_thread("alice", "Scheduled topic")

      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "threaded",
                 target_type: "runtime_prompt",
                 target: %{text: "Follow up."},
                 schedule: %{kind: "manual"},
                 user_id: "alice",
                 thread_id: thread.id
               })

      assert job.thread_mode == "origin_thread"
      assert job.thread_id == thread.id

      assert {:error, {:thread_not_found, thread_id}} =
               Jobs.create_job(%{
                 name: "wrong user",
                 target_type: "runtime_prompt",
                 target: %{text: "Follow up."},
                 schedule: %{kind: "manual"},
                 user_id: "bob",
                 thread_id: thread.id
               })

      assert thread_id == thread.id
    end

    test "lists, pauses, resumes, and records runs for user-owned jobs" do
      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "active brief",
                 target_type: "runtime_prompt",
                 target: %{text: "Brief me."},
                 schedule: %{kind: "daily", at: "08:00"},
                 timezone: "UTC",
                 status: "active",
                 user_id: "alice",
                 session_id: "sess_1",
                 app_id: "allbert"
               })

      assert [listed] = Jobs.list_jobs("alice")
      assert listed.id == job.id
      assert [] = Jobs.list_jobs("bob")

      assert {:ok, paused} = Jobs.pause_job(job)
      assert paused.status == "paused"
      assert paused.next_due_at == nil

      assert {:ok, resumed} = Jobs.resume_job(paused)
      assert resumed.status == "active"
      assert %DateTime{} = resumed.next_due_at

      assert {:ok, %Run{} = run} = Jobs.create_run(resumed, %{trigger: "manual"})
      assert String.starts_with?(run.id, "run_")
      assert run.status == "queued"
      assert run.user_id == "alice"
      assert run.session_id == "sess_1"
      assert run.app_id == "allbert"

      assert [%Run{id: run_id}] = Jobs.list_runs(resumed)
      assert run_id == run.id
    end

    test "blocked jobs only resume after their confirmation is resolved" do
      assert {:ok, confirmation} = create_pending_confirmation("conf_resume_job")

      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "blocked brief",
                 target_type: "runtime_prompt",
                 target: %{text: "Brief me."},
                 schedule: %{kind: "daily", at: "08:00"},
                 timezone: "UTC",
                 status: "active",
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

      assert {:error, {:blocked_by_confirmation, "conf_resume_job"}} =
               Jobs.resume_job(blocked_job)

      assert Repo.reload!(blocked_job).status == "blocked"

      assert {:ok, _resolved} =
               Confirmations.resolve(
                 "conf_resume_job",
                 :denied,
                 %{
                   resolver_actor: "alice",
                   resolver_channel: :cli,
                   resolution_reason: "not needed"
                 }
               )

      assert {:ok, resumed} = Jobs.resume_job(blocked_job)
      assert resumed.status == "active"
      assert resumed.blocked_confirmation_id == nil
      assert %DateTime{} = resumed.next_due_at
    end
  end

  describe "runner" do
    test "runs runtime prompt jobs through the runtime boundary" do
      parent = self()

      Application.put_env(:allbert_assist, Runtime,
        agent_runner: fn _signal, request ->
          send(parent, {:runtime_request, request})

          {:ok,
           %{
             message: "Job runtime response: #{request.text}",
             status: :completed,
             actions: [%{name: "direct_answer", status: :completed}],
             decision: %{selected_action: "direct_answer"},
             resource_access: [%{operation_class: "read_only"}]
           }}
        end
      )

      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "runtime run",
                 target_type: "runtime_prompt",
                 target: %{text: "Run from job."},
                 schedule: %{kind: "manual"},
                 user_id: "alice",
                 session_id: "sess_job",
                 app_id: "allbert"
               })

      assert {:ok, %{job: updated_job, run: run, response: response}} = Runner.run_now(job)

      assert run.status == "completed"
      assert run.user_id == "alice"
      assert run.session_id == "sess_job"
      assert run.app_id == "allbert"
      assert String.starts_with?(run.thread_id, "thr_")
      assert is_binary(run.input_signal_id)
      assert is_binary(run.response_signal_id)
      assert run.decision == %{"selected_action" => "direct_answer"}
      assert run.resource_access == %{"entries" => [%{"operation_class" => "read_only"}]}
      assert run.action_log["status"] == "completed"
      assert response.message == "Job runtime response: Run from job."
      assert updated_job.last_run_at == run.finished_at

      assert_received {:runtime_request,
                       %{
                         channel: :job,
                         user_id: "alice",
                         operator_id: "alice",
                         session_id: "sess_job",
                         metadata: %{job_id: job_id}
                       }}

      assert job_id == job.id

      assert {:ok, %{messages: messages}} = Conversations.show_thread("alice", run.thread_id)
      assert Enum.map(messages, & &1.role) == ["user", "assistant"]
    end

    test "runtime prompt jobs inherit active app context from session scratchpad" do
      user = "job-session-#{System.unique_integer([:positive])}"
      session_id = "sess-1"
      ensure_stocksage_app!()

      on_exit(fn -> Session.clear(user, session_id) end)

      assert {:ok, _entry} = Session.set_active_app(user, session_id, :stocksage)

      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "session runtime job",
                 target_type: "runtime_prompt",
                 target: %{text: "Hello from session context."},
                 schedule: %{kind: "manual"},
                 user_id: user,
                 session_id: session_id
               })

      assert {:ok, %{run: run, response: response}} = Runner.run_now(job)

      assert response.active_app == :stocksage
      assert run.action_log["active_app"] == "stocksage"

      assert {:ok, entry} = Session.get(user, session_id)
      assert entry.active_app == :stocksage
    end

    test "new_thread_per_run creates a fresh conversation thread for each run" do
      Application.put_env(:allbert_assist, Runtime,
        agent_runner: fn _signal, request ->
          {:ok,
           %{
             message: "New thread response: #{request.text}",
             status: :completed,
             actions: [%{name: "direct_answer", status: :completed}]
           }}
        end
      )

      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "fresh thread",
                 target_type: "runtime_prompt",
                 target: %{text: "Start fresh."},
                 schedule: %{kind: "manual"},
                 user_id: "alice",
                 thread_mode: "new_thread_per_run"
               })

      assert {:ok, %{run: first_run}} = Runner.run_now(job)
      assert {:ok, %{run: second_run}} = Runner.run_now(job)

      assert first_run.thread_id != second_run.thread_id
      assert [_first, _second] = Conversations.list_threads("alice")

      assert {:ok, %{messages: first_messages}} =
               Conversations.show_thread("alice", first_run.thread_id)

      assert {:ok, %{messages: second_messages}} =
               Conversations.show_thread("alice", second_run.thread_id)

      assert Enum.map(first_messages, & &1.role) == ["user", "assistant"]
      assert Enum.map(second_messages, & &1.role) == ["user", "assistant"]
    end

    test "origin-thread jobs fail their run if the thread was deleted after creation" do
      assert {:ok, thread} = Conversations.create_general_thread("alice", "Temporary topic")

      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "deleted thread",
                 target_type: "runtime_prompt",
                 target: %{text: "Follow up."},
                 schedule: %{kind: "manual"},
                 user_id: "alice",
                 thread_id: thread.id
               })

      assert {:ok, _deleted_thread} = Repo.delete(thread)

      assert {:ok, %{run: run, response: nil}} = Runner.run_now(job)
      assert run.status == "failed"
      assert run.error.reason =~ "{:thread_not_found, \"#{thread.id}\"}"
    end

    test "runs registered action jobs through the action runner" do
      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "direct action",
                 target_type: "registered_action",
                 target: %{
                   action_name: "direct_answer",
                   params: %{"text" => "Hello from action job."}
                 },
                 schedule: %{kind: "manual"},
                 user_id: "alice",
                 thread_id: "thr_origin"
               })

      assert {:ok, %{run: run, response: response}} = Runner.run_now(job)

      assert run.status == "completed"
      assert run.thread_id == "thr_origin"
      assert is_binary(run.input_signal_id)
      assert is_binary(run.response_signal_id)
      assert get_in(run.action_log, ["runner_metadata", "action_name"]) == "direct_answer"
      assert response.runner_metadata.action_name == "direct_answer"
    end

    test "persists failed runtime runs without losing the run record" do
      Application.put_env(:allbert_assist, Runtime,
        agent_runner: fn _signal, _request -> {:error, :boom} end
      )

      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "runtime failure",
                 target_type: "runtime_prompt",
                 target: %{text: "This will fail."},
                 schedule: %{kind: "manual"},
                 user_id: "alice"
               })

      assert {:ok, %{run: run, response: nil}} = Runner.run_now(job)

      assert run.status == "failed"
      assert run.error.reason =~ ":boom"
      assert %DateTime{} = run.finished_at
      assert is_integer(run.duration_ms)
    end

    test "blocks jobs when a run needs confirmation" do
      Application.put_env(:allbert_assist, Runtime,
        agent_runner: fn _signal, _request ->
          {:ok,
           %{
             message: "Approval required.",
             status: :needs_confirmation,
             actions: [%{name: "external_network_request", status: :needs_confirmation}],
             approval_handoff: %{confirmation_id: "cnf_job_1", status: :pending}
           }}
        end
      )

      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "confirmation job",
                 target_type: "runtime_prompt",
                 target: %{text: "Fetch https://example.com"},
                 schedule: %{kind: "daily", at: "08:00"},
                 timezone: "UTC",
                 status: "active",
                 user_id: "alice"
               })

      assert {:ok, %{job: blocked_job, run: run}} = Runner.run_now(job)

      assert run.status == "needs_confirmation"
      assert run.confirmation_id == "cnf_job_1"
      assert blocked_job.status == "blocked"
      assert blocked_job.blocked_confirmation_id == "cnf_job_1"
      assert blocked_job.next_due_at == nil
    end

    test "rejects manual runs for blocked jobs without creating duplicate runs" do
      assert {:ok, confirmation} = create_pending_confirmation("conf_run_now_blocked")

      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "blocked manual run",
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

      assert {:error, {:blocked_by_confirmation, "conf_run_now_blocked"}} =
               Runner.run_now(blocked_job)

      assert [] = Jobs.list_runs(blocked_job)
    end

    test "registered action confirmations preserve job origin and block duplicate scheduling" do
      configure_external_request_settings()
      now = ~U[2026-05-14 08:00:00Z]

      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "network job",
                 target_type: "registered_action",
                 target: %{
                   action_name: "external_network_request",
                   params: %{"request" => "fetch https://example.com/"}
                 },
                 schedule: %{kind: "daily", at: "08:00"},
                 timezone: "UTC",
                 status: "active",
                 user_id: "alice",
                 app_id: "allbert"
               })

      assert {:ok, due_job} =
               job
               |> Job.changeset(%{next_due_at: DateTime.add(now, -60, :second)})
               |> Repo.update()

      assert {:ok, %{job: blocked_job, run: run}} = Runner.run_now(due_job)

      assert run.status == "needs_confirmation"
      assert is_binary(run.confirmation_id)
      assert blocked_job.status == "blocked"
      assert blocked_job.blocked_confirmation_id == run.confirmation_id

      assert {:ok, confirmation} = Confirmations.read(run.confirmation_id)
      origin = confirmation["origin"]
      assert origin["channel"] == "job"
      assert origin["user_id"] == "alice"
      assert origin["operator_id"] == "alice"
      assert origin["job_id"] == due_job.id
      assert origin["run_id"] == run.id
      assert origin["app_id"] == "allbert"

      scheduler = start_test_scheduler(cleanup_on_start?: false)

      assert {:ok, %{claimed: 0, completed: 0, needs_confirmation: 0}} =
               Scheduler.run_once(scheduler, now)

      assert [%Run{}] = Jobs.list_runs(blocked_job)
    end
  end

  describe "scheduler" do
    test "run_once claims due jobs, executes them, and advances next due time" do
      Application.put_env(:allbert_assist, Runtime,
        agent_runner: fn _signal, request ->
          {:ok,
           %{
             message: "Scheduled response: #{request.text}",
             status: :completed,
             actions: [%{name: "direct_answer", status: :completed}]
           }}
        end
      )

      now = ~U[2026-05-14 08:00:00Z]

      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "due job",
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

      assert {:ok,
              %{
                policy: "operator_approved",
                claimed: 1,
                completed: 1,
                needs_confirmation: 0,
                failed: 0,
                skipped: 0
              }} = Scheduler.run_once(scheduler, now)

      assert [%Run{status: "completed", trigger: "scheduler"}] = Jobs.list_runs(due_job)

      reloaded = Repo.reload!(due_job)
      assert reloaded.last_run_at
      assert DateTime.compare(reloaded.next_due_at, now) == :gt
    end

    test "paused schedule policy prevents due job claims" do
      assert {:ok, _policy} = Settings.put("jobs.schedule_policy", "paused", %{audit?: false})

      now = ~U[2026-05-14 08:00:00Z]

      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "paused due job",
                 target_type: "runtime_prompt",
                 target: %{text: "Should not run."},
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

      assert {:ok, %{policy: "paused", claimed: 0}} = Scheduler.run_once(scheduler, now)
      assert [] = Jobs.list_runs(due_job)
    end

    test "open runs cause due jobs to be skipped without duplicate claims" do
      now = ~U[2026-05-14 08:00:00Z]

      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "open run job",
                 target_type: "runtime_prompt",
                 target: %{text: "Already running."},
                 schedule: %{kind: "daily", at: "08:00"},
                 timezone: "UTC",
                 status: "active",
                 user_id: "alice"
               })

      assert {:ok, due_job} =
               job
               |> Job.changeset(%{next_due_at: DateTime.add(now, -60, :second)})
               |> Repo.update()

      assert {:ok, _open_run} =
               Jobs.create_run(due_job, %{
                 trigger: "scheduler",
                 status: "running",
                 started_at: DateTime.add(now, -30, :second)
               })

      scheduler = start_test_scheduler(cleanup_on_start?: false)

      assert {:ok, %{claimed: 0, skipped: 1}} = Scheduler.run_once(scheduler, now)
      assert [%Run{status: "running"}] = Jobs.list_runs(due_job)
    end

    test "startup cleanup fails stale running runs after scheduler restart" do
      now = ~U[2026-05-14 08:00:00Z]

      assert {:ok, job} =
               Jobs.create_job(%{
                 name: "stale run job",
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

      reloaded = Repo.reload!(run)
      assert reloaded.status == "failed"
      assert reloaded.finished_at

      assert reloaded.error in [
               %{kind: "scheduler_restarted"},
               %{"kind" => "scheduler_restarted"}
             ]
    end
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(_module, nil), do: :ok

  defp restore_app_env(module, config) do
    Application.put_env(:allbert_assist, module, config)
  end

  defp ensure_stocksage_app! do
    case AppRegistry.lookup(:stocksage) do
      {:ok, _entry} ->
        :ok

      {:error, :not_found} ->
        PluginRegistry.register_module(StockSage.Plugin)
        assert {:ok, :stocksage} = AppRegistry.register(StockSage.App)
        on_exit(fn -> AppRegistry.unregister(:stocksage) end)
    end
  end

  defp start_test_scheduler(opts) do
    name = :"allbert_jobs_scheduler_#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      enabled?: true,
      poll_on_start?: false,
      cleanup_on_start?: false,
      interval_ms: 60_000
    ]

    start_supervised!({Scheduler, Keyword.merge(defaults, opts)})
  end

  defp configure_external_request_settings do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/"], %{audit?: false})
  end

  defp create_pending_confirmation(id) do
    Confirmations.create(%{
      id: id,
      origin: %{
        actor: "alice",
        channel: :job,
        surface: "scheduled_job"
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
