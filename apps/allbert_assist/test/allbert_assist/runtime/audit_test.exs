defmodule AllbertAssist.Runtime.AuditTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Execution.Audit, as: ShellAudit
  alias AllbertAssist.Execution.CommandSpec
  alias AllbertAssist.Runtime.Audit
  alias AllbertAssist.Security.Audit, as: SecurityAudit

  setup do
    original_audit_config = Application.get_env(:allbert_assist, ShellAudit)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-runtime-audit-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, ShellAudit, root: root)

    on_exit(fn ->
      restore_env(ShellAudit, original_audit_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "security event facade preserves Security Central audit shape" do
    decision = %{
      permission: :memory_write,
      decision: :allowed,
      reason: "allowed for test",
      context: %{
        actor: %{id: "operator"},
        channel: %{name: "cli"},
        action: %{name: "memory_write"}
      },
      policy: %{source: :test_policy}
    }

    assert Audit.security_event(decision) == SecurityAudit.event(decision)
  end

  test "append routes shell command audit through existing writer", %{root: root} do
    spec = %CommandSpec{
      executable: "pwd",
      args: [],
      cwd: root,
      resolved_cwd: root,
      timeout_ms: 1000,
      max_output_bytes: 2048,
      env_summary: [],
      command_class: :read_only,
      sandbox_level: 1,
      policy_decision: :allowed
    }

    assert {:ok, path} =
             Audit.append(:shell_command, :requested, spec, %{decision: :needs_confirmation}, %{
               confirmation_id: "conf-test"
             })

    assert path == Audit.audit_path(:shell_command)
    assert Path.dirname(path) == Audit.audit_root(:shell_command)

    audit = File.read!(path)
    assert audit =~ "event: requested"
    assert audit =~ "confirmation_id: conf-test"
    assert audit =~ "executable: pwd"
  end

  test "audit path facade preserves monthly path calculation" do
    now = ~U[2026-05-22 12:34:56Z]

    assert Audit.audit_path(:shell_command, now) == ShellAudit.audit_path(now)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
