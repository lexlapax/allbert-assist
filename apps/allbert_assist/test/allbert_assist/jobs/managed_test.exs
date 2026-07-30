defmodule AllbertAssist.Jobs.ManagedTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Managed
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Jobs.Runner
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-managed-jobs-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Settings, original_settings)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "reconcile creates exactly five visible ordinary jobs and is idempotent" do
    assert {:ok, first} = Managed.reconcile("local")
    assert Enum.all?(first, &(&1.outcome == :created and not &1.degraded?))

    jobs =
      Jobs.list_jobs("local", limit: 100)
      |> Enum.filter(&(&1.name in managed_names()))

    assert Enum.map(jobs, & &1.name) == Enum.sort(managed_names())

    Enum.each(jobs, fn job ->
      assert job.metadata["managed_by"] == "jobs.managed"
      assert job.metadata["managed_identity"] == job.name
      assert job.metadata["managed_schema"] == 1
      assert job.metadata["managed_spec_version"] == 1
      assert job.metadata["managed_spec_digest"] =~ ~r/^sha256:[0-9a-f]{64}$/
      assert job.metadata["dirty_seq"] == 0
    end)

    consolidation = Enum.find(jobs, &(&1.name == "memory-consolidation"))
    refute consolidation.metadata["feature_enabled"]
    assert consolidation.next_due_at == nil

    search_rebuild = Enum.find(jobs, &(&1.name == "search-rebuild"))
    assert search_rebuild.status == "active"
    assert search_rebuild.next_due_at == nil

    ids = Map.new(jobs, &{&1.name, &1.id})
    assert {:ok, second} = Managed.reconcile("local")
    assert Enum.all?(second, &(&1.outcome == :current))

    assert Jobs.list_jobs("local", limit: 100)
           |> Enum.filter(&(&1.name in managed_names()))
           |> Map.new(&{&1.name, &1.id}) == ids
  end

  test "reserved operator row conflicts without overwrite or duplicate" do
    assert {:ok, operator_job} =
             Jobs.create_job(%{
               name: "search-index",
               target_type: "runtime_prompt",
               target: %{text: "operator-owned"},
               schedule: %{kind: "manual"},
               status: "paused",
               user_id: "local"
             })

    assert {:ok, results} = Managed.reconcile("local")

    assert %{outcome: :managed_name_conflict, degraded?: true, job_id: id} =
             Enum.find(results, &(&1.managed_identity == "search-index"))

    assert id == operator_job.id
    assert [same] = Enum.filter(Jobs.list_jobs("local", limit: 100), &(&1.name == "search-index"))
    assert same.id == operator_job.id
    assert same.target == %{"text" => "operator-owned"}
  end

  test "owned metadata drift fails admission closed" do
    assert {:ok, _results} = Managed.reconcile("local")
    search = managed_job("search-index")

    assert {:ok, drifted} =
             search
             |> Job.changeset(%{
               metadata:
                 Map.put(
                   search.metadata,
                   "managed_spec_digest",
                   "sha256:" <> String.duplicate("0", 64)
                 )
             })
             |> Repo.update()

    assert Managed.managed?(drifted)
    assert {:error, :managed_invariant_drift} = Jobs.admit_run(drifted, %{trigger: "manual"})
  end

  test "exact review-cadence legacy row is adopted in place with history and pause preserved" do
    assert {:ok, legacy} =
             Jobs.create_job(%{
               name: "memory-index-rebuild",
               target_type: "registered_action",
               target: %{action_name: "compile_memory_index", params: %{}},
               schedule: %{kind: "weekly", weekday: "sunday", at: "03:00"},
               status: "paused",
               user_id: "local",
               metadata: %{
                 "template_name" => "memory-index-rebuild",
                 "managed_by" => "memory.review_cadence",
                 "cadence" => "weekly"
               }
             })

    assert {:ok, historical_run} = Jobs.create_run(legacy, %{status: "completed"})
    assert {:ok, results} = Managed.reconcile("local")

    assert %{outcome: :adopted, job_id: adopted_id} =
             Enum.find(results, &(&1.managed_identity == "memory-index-rebuild"))

    assert adopted_id == legacy.id
    assert {:ok, adopted} = Jobs.get_job(legacy.id)
    assert adopted.status == "paused"
    assert adopted.schedule == legacy.schedule
    assert adopted.target["action_name"] == "rebuild_memory_projection"
    assert adopted.metadata["managed_by"] == "jobs.managed"
    assert [%Run{id: run_id}] = Jobs.list_runs(adopted)
    assert run_id == historical_run.id
  end

  test "the retained projection template is adopted instead of conflicting" do
    assert {:ok, template_job} =
             Jobs.create_job(%{
               name: "memory-index-rebuild",
               target_type: "registered_action",
               target: %{action_name: "rebuild_memory_projection", params: %{}},
               schedule: %{kind: "manual"},
               status: "active",
               user_id: "local",
               metadata: %{"template_name" => "memory-index-rebuild"}
             })

    assert {:ok, result} = Managed.reconcile_identity("memory-index-rebuild", "local")
    assert result.outcome == :adopted
    assert result.job_id == template_job.id

    assert {:ok, adopted} = Jobs.get_job(template_job.id)
    assert adopted.target["action_name"] == "rebuild_memory_projection"
    assert adopted.metadata["managed_by"] == "jobs.managed"
    assert adopted.metadata["managed_identity"] == "memory-index-rebuild"
  end

  test "dirty kick coalesces admission and completion preserves a racing kick" do
    assert {:ok, _results} = Managed.reconcile("local")
    search = managed_job("search-index")
    assert {:ok, paused} = Jobs.pause_job(search)

    assert {:ok, first_kick} = Managed.kick("search-index", "local")
    assert first_kick.status == "paused"
    assert first_kick.dirty_seq == 1
    assert [] = Jobs.list_runs(paused)

    assert {:ok, resumed} = Jobs.resume_job(paused)
    assert resumed.status == "active"
    assert %DateTime{} = resumed.next_due_at

    assert {:ok, %Run{} = admitted} =
             Jobs.admit_run(resumed, %{trigger: "kick", due_at: resumed.next_due_at})

    assert admitted.admission_key == resumed.id
    assert admitted.metadata["managed_identity"] == "search-index"
    assert admitted.metadata["claimed_dirty_seq"] == 1

    assert {:ok,
            %{
              outcome: :coalesced,
              open_run_id: open_run_id,
              claimed_dirty_seq: 1
            }} = Jobs.admit_run(resumed, %{trigger: "manual"})

    assert open_run_id == admitted.id

    assert {:ok, %{outcome: :coalesced, run: %Run{id: ^open_run_id}, response: nil}} =
             Runner.run_now(resumed)

    assert {:ok, second_kick} = Managed.kick("search-index", "local")
    assert second_kick.dirty_seq == 2

    assert {:ok, completed} =
             Jobs.update_run(admitted, %{status: "completed", finished_at: DateTime.utc_now()})

    assert {:ok, after_completion} = Managed.complete_run(resumed, completed)
    assert after_completion.metadata["dirty_seq"] == 2
    assert after_completion.metadata["clean_dirty_seq"] == 0
    assert %DateTime{} = after_completion.next_due_at
  end

  test "disabled managed feature retains dirty intent and rejects ordinary admission" do
    assert {:ok, _results} = Managed.reconcile("local")
    consolidation = managed_job("memory-consolidation")

    assert {:ok, kicked} = Managed.kick("memory-consolidation", "local")
    assert kicked.dirty_seq == 1
    assert kicked.due_at == nil

    assert {:ok, paused} = Jobs.pause_job(consolidation)
    assert {:ok, resumed_disabled} = Jobs.resume_job(paused)
    assert resumed_disabled.next_due_at == nil

    assert {:error, :managed_feature_disabled} =
             Jobs.admit_run(resumed_disabled, %{trigger: "manual"})

    assert {:ok, synthetic_run} =
             Jobs.create_run(resumed_disabled, %{
               status: "completed",
               metadata: %{"claimed_dirty_seq" => 1}
             })

    assert {:ok, completed_disabled} =
             Managed.complete_run(resumed_disabled, synthetic_run)

    assert completed_disabled.next_due_at == nil

    assert {:ok, _setting} = Settings.put("memory.consolidation.enabled", true)

    assert {:ok, _epoch} =
             Corpus.set_origin_grant(
               :memory,
               :local_operator,
               true
             )

    assert {:ok, results} = Managed.reconcile("local")

    assert %{outcome: :updated} =
             Enum.find(results, &(&1.managed_identity == "memory-consolidation"))

    enabled = managed_job("memory-consolidation")
    assert enabled.metadata["feature_enabled"]
    assert %DateTime{} = enabled.next_due_at
  end

  test "enabled consolidation executes through ordinary Jobs admission and the action runner" do
    assert {:ok, _setting} = Settings.put("memory.consolidation.enabled", true)

    assert {:ok, _epoch} =
             Corpus.set_origin_grant(
               :memory,
               :local_operator,
               true
             )

    assert {:ok, thread} = Conversations.create_general_thread("local", "Managed Memory")

    assert {:ok, _message} =
             Conversations.append_user_message(thread, "I prefer managed proposal review.",
               metadata: %{"channel" => "tui"}
             )

    assert {:ok, _results} = Managed.reconcile("local")
    consolidation = managed_job("memory-consolidation")

    assert consolidation.metadata["feature_enabled"]

    assert {:ok, %{run: run, response: response}} = Runner.run_now(consolidation)
    assert run.status == "completed"
    assert response.status == :completed
    assert response.result.created == 1
    assert response.result.hosted_transport_count == 0
    assert run.metadata["managed_identity"] == "memory-consolidation"
  end

  test "legacy open run without admission key is still coalesced" do
    assert {:ok, _results} = Managed.reconcile("local")
    search = managed_job("search-index")
    assert {:ok, open} = Jobs.create_run(search, %{status: "running", trigger: "scheduler"})

    from(run in Run, where: run.id == ^open.id)
    |> Repo.update_all(set: [admission_key: nil])

    assert {:ok, %{outcome: :coalesced, open_run_id: open_id}} =
             Jobs.admit_run(search, %{trigger: "kick"})

    assert open_id == open.id
    assert length(Jobs.list_runs(search)) == 1
  end

  test "canonical conversation commits only mark and kick the existing search entry" do
    assert {:ok, _results} = Managed.reconcile("local")
    before = managed_job("search-index")
    assert before.metadata["dirty_seq"] == 0

    assert {:ok, thread} = Conversations.create_general_thread("local", "Managed dirty")

    assert {:ok, _message} =
             Conversations.append_user_message(thread, "new canonical content",
               metadata: %{"channel" => "tui"}
             )

    after_write = managed_job("search-index")
    assert after_write.metadata["dirty_seq"] == 1
    assert %DateTime{} = after_write.next_due_at
    assert Jobs.list_runs(after_write) == []
  end

  defp managed_job(name) do
    Jobs.list_jobs("local", limit: 100)
    |> Enum.find(&(&1.name == name))
  end

  defp managed_names do
    ~w[memory-consolidation memory-index-rebuild search-index search-maintain search-rebuild]
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
