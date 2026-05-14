defmodule AllbertAssist.JobsTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Conversations
  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @env_vars ["ALLBERT_HOME", "ALLBERT_HOME_DIR", "ALLBERT_SETTINGS_ROOT"]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home = Path.join(System.tmp_dir!(), "allbert-jobs-test-#{System.unique_integer([:positive])}")
    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
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
end
