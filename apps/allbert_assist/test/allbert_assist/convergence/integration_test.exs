defmodule AllbertAssist.Convergence.IntegrationTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Run
  alias AllbertAssist.Jobs.Scheduler
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Trace

  @env_vars ["ALLBERT_HOME", "ALLBERT_HOME_DIR", "ALLBERT_SETTINGS_ROOT"]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Runtime)
    Application.delete_env(:allbert_assist, Settings)
    Application.delete_env(:allbert_assist, Trace)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-convergence-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Runtime, original_runtime_config)
      restore_app_env(Settings, original_settings_config)
      restore_app_env(Trace, original_trace_config)
    end)

    {:ok, home: home}
  end

  test "confirmation lifecycle still flows through registered actions" do
    assert {:ok, record} = Confirmations.create(base_confirmation("conf_converge"))

    assert {:ok, list_response} =
             Runner.run("list_confirmations", %{}, %{actor: "local", channel: :test})

    assert Enum.any?(list_response.confirmations, &(&1["id"] == record["id"]))

    assert {:ok, show_response} =
             Runner.run("show_confirmation", %{id: record["id"]}, %{
               actor: "local",
               channel: :test
             })

    assert show_response.confirmation["id"] == record["id"]

    assert {:ok, approve_response} =
             Runner.run("approve_confirmation", %{id: record["id"], reason: "integration"}, %{
               actor: "local",
               channel: :cli
             })

    assert approve_response.status == :completed
    assert approve_response.confirmation["status"] == "adapter_unavailable"
  end

  test "confirmation expiry and TTL settings still apply to new records" do
    assert {:ok, _ttl} =
             Settings.put("confirmations.default_ttl_minutes", 1, %{audit?: false})

    assert {:ok, record} =
             Confirmations.create(
               base_confirmation("conf_expiry"),
               now: ~U[2026-05-14 08:00:00Z]
             )

    assert record["expires_at"] == "2026-05-14T08:01:00Z"

    assert {:ok, [{:ok, expired}]} =
             Confirmations.expire(now: ~U[2026-05-14 08:02:00Z])

    assert expired["id"] == record["id"]
    assert expired["status"] == "expired"
  end

  test "scheduler run blocks risky registered actions behind confirmations" do
    configure_external_request_settings()
    now = ~U[2026-05-14 08:00:00Z]

    assert {:ok, job} =
             Jobs.create_job(%{
               name: "convergence network job",
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

    scheduler = start_test_scheduler(cleanup_on_start?: false)

    assert {:ok, %{claimed: 1, needs_confirmation: 1}} =
             Scheduler.run_once(scheduler, now)

    assert [%Run{status: "needs_confirmation", confirmation_id: confirmation_id}] =
             Jobs.list_runs(due_job)

    assert {:ok, confirmation} = Confirmations.read(confirmation_id)
    assert confirmation["origin"]["job_id"] == due_job.id

    blocked_job = Repo.reload!(due_job)
    assert blocked_job.status == "blocked"

    assert {:error, {:blocked_by_confirmation, ^confirmation_id}} =
             Jobs.resume_job(blocked_job)

    assert {:ok, _resolved} =
             Confirmations.resolve(
               confirmation_id,
               :denied,
               %{resolver_actor: "alice", resolver_channel: :cli}
             )

    assert {:ok, resumed} = Jobs.resume_job(blocked_job)
    assert resumed.status == "active"
    assert resumed.blocked_confirmation_id == nil
  end

  defp start_test_scheduler(opts) do
    name = :"allbert_convergence_scheduler_#{System.unique_integer([:positive])}"

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

  defp base_confirmation(id) do
    %{
      id: id,
      origin: %{actor: "local", channel: :cli, surface: "mix allbert.ask"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{url: "https://example.com"},
      resume_params_ref: %{url: "https://example.com"}
    }
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(_module, nil), do: :ok
  defp restore_app_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
