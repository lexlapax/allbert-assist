defmodule AllbertAssist.Confirmations.StoreGoldenTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Confirmations.Store
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @fixture_root Path.expand("../../fixtures/v0.23/confirmations", __DIR__)
  @env_vars ["ALLBERT_HOME", "ALLBERT_HOME_DIR"]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-store-golden-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
    end)

    {:ok, home: home}
  end

  test "requested external-network audit markdown matches the v0.23 fixture", %{home: home} do
    assert {:ok, _record} = Store.create(external_attrs(), now: now())

    assert audit(home) == fixture("requested_external_network.md")
  end

  test "approved shell-command audit markdown matches the v0.23 fixture", %{home: home} do
    assert {:ok, record} = Store.create(shell_attrs(), now: now())

    assert {:ok, _resolved} =
             Store.resolve(
               record["id"],
               :approved,
               %{
                 resolver_actor: "alice",
                 resolver_channel: :cli,
                 resolver_surface: "mix allbert.confirmations approve",
                 resolution_reason: "approved golden shell",
                 same_channel?: true,
                 target_status: "completed",
                 target_result: %{
                   status: "completed",
                   exit_status: 0,
                   timed_out?: false,
                   truncated?: false,
                   output_bytes: 12,
                   stdout_preview: "ok\n"
                 }
               },
               now: DateTime.add(now(), 60, :second)
             )

    assert audit(home) == fixture("approved_shell_command.md")
  end

  test "denied package-install audit markdown matches the v0.23 fixture", %{home: home} do
    assert {:ok, record} = Store.create(package_attrs(), now: now())

    assert {:ok, _resolved} =
             Store.resolve(
               record["id"],
               :denied,
               %{
                 resolver_actor: "alice",
                 resolver_channel: :liveview,
                 resolver_surface: "/workspace",
                 resolution_reason: "package not needed",
                 same_channel?: false
               },
               now: DateTime.add(now(), 60, :second)
             )

    assert audit(home) == fixture("denied_package_install.md")
  end

  test "expired skill-script audit markdown matches the v0.23 fixture", %{home: home} do
    assert {:ok, _record} = Store.create(skill_script_attrs(), now: now(), ttl_minutes: 1)

    assert {:ok, [_expired]} =
             Store.expire(
               now: DateTime.add(now(), 61, :second),
               resolution_attrs: %{
                 resolver_actor: "system",
                 resolver_channel: :scheduler,
                 resolver_surface: "expiry sweep",
                 resolution_reason: "ttl elapsed",
                 decision_source: "system_ttl"
               }
             )

    assert audit(home) == fixture("expired_skill_script.md")
  end

  test "cancelled resource-reference audit markdown matches the v0.23 fixture", %{home: home} do
    assert {:ok, record} = Store.create(resource_attrs(), now: now())

    assert {:ok, _resolved} =
             Store.resolve(
               record["id"],
               :cancelled,
               %{
                 resolver_actor: "alice",
                 resolver_channel: :cli,
                 resolver_surface: "mix allbert.confirmations cancel",
                 resolution_reason: "operator cancelled",
                 same_channel?: true
               },
               now: DateTime.add(now(), 60, :second)
             )

    assert audit(home) == fixture("cancelled_resource_reference.md")
  end

  defp external_attrs do
    %{
      id: "conf_golden_external",
      origin: %{actor: "local", channel: :cli, surface: "mix allbert.ask"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      source_trace_id: "trace-external",
      params_summary: %{url: "https://example.com"}
    }
  end

  defp shell_attrs do
    %{
      id: "conf_golden_shell",
      origin: %{actor: "alice", channel: :cli, surface: "mix allbert.ask"},
      target_action: %{name: "run_shell_command"},
      target_permission: :shell_command,
      target_execution_mode: :local_policy_sandbox,
      security_decision: %{permission: :shell_command, decision: :needs_confirmation},
      source_trace_id: "trace-shell",
      params_summary: %{
        executable: "mix",
        args: ["test"],
        resolved_cwd: "/tmp/allbert",
        sandbox_level: 1,
        timeout_ms: 1000,
        max_output_bytes: 4096
      }
    }
  end

  defp package_attrs do
    %{
      id: "conf_golden_package",
      origin: %{actor: "alice", channel: :cli, surface: "mix allbert.packages"},
      target_action: %{name: "run_package_install"},
      target_permission: :package_install,
      target_execution_mode: :local_policy_sandbox,
      security_decision: %{permission: :package_install, decision: :needs_confirmation},
      source_trace_id: "trace-package",
      params_summary: %{
        manager: "mix",
        packages: ["req", "nx"],
        target_root: "/tmp/allbert",
        dry_run_argv: ["mix", "deps.get", "--dry-run"],
        execution_argv_preview: ["mix", "deps.get"],
        execution_available?: false,
        timeout_ms: 5000,
        max_output_bytes: 8192
      }
    }
  end

  defp skill_script_attrs do
    %{
      id: "conf_golden_skill",
      origin: %{actor: "alice", channel: :cli, surface: "mix allbert.skills"},
      target_action: %{name: "run_skill_script"},
      target_permission: :skill_script,
      target_execution_mode: :local_policy_sandbox,
      security_decision: %{permission: :skill_script, decision: :needs_confirmation},
      source_trace_id: "trace-skill",
      params_summary: %{
        skill_name: "reporter",
        script_path: "scripts/report.exs",
        script_sha256: "abc123",
        resolved_cwd: "/tmp/allbert",
        sandbox_level: 1,
        timeout_ms: 2000,
        max_output_bytes: 2048,
        env_keys: ["ALLBERT_HOME"]
      }
    }
  end

  defp resource_attrs do
    %{
      id: "conf_golden_resource",
      origin: %{actor: "alice", channel: :cli, surface: "mix allbert.ask"},
      target_action: %{name: "direct_answer"},
      target_permission: :read_only,
      target_execution_mode: :read_only,
      security_decision: %{permission: :read_only, decision: :needs_confirmation},
      source_trace_id: "trace-resource",
      params_summary: %{
        resource_refs: [
          %{
            origin_kind: "prompt_context",
            operation_class: "url_summary",
            access_mode: "read",
            scope: %{kind: "exact_url", value: "https://example.com/page"},
            downstream_consumer: "intent"
          }
        ]
      }
    }
  end

  defp audit(home), do: File.read!(Path.join([home, "confirmations", "audit", "2026-05.md"]))

  defp fixture(name) do
    @fixture_root
    |> Path.join(name)
    |> File.read!()
  end

  defp now, do: ~U[2026-05-02 12:00:00Z]

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
