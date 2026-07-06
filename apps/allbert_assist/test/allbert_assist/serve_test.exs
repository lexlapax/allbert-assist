defmodule AllbertAssist.ServeTest do
  @moduledoc """
  v0.62 M5 — health snapshot + per-user service management. The health read is
  bounded and read-only; service install/uninstall are named internal actions
  gated behind :command_execute + confirmation (never off-spine shell); the
  rendered unit pins WorkingDirectory to Allbert Home (closing the cwd-scope
  widening) and sets SHELL (the M0 erlexec finding).
  """
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Actions.Serve.ServiceControl
  alias AllbertAssist.Health
  alias AllbertAssist.Service

  @moduletag :serve_daemon

  test "Health.snapshot reports runtime/database/channels bounded" do
    snap = Health.snapshot()
    assert snap.status in [:ok, :degraded]
    assert snap.runtime in [:up, :down]
    assert snap.database in [:ok, :error]
    assert is_map(snap.channels)
  end

  test "serve_health action is read-only and returns the snapshot + service posture" do
    assert {:ok, %{status: :completed, health: health}} =
             Runner.run("serve_health", %{}, %{user_id: "local"})

    assert Map.has_key?(health, :status)
    assert Map.has_key?(health, :service_platform)
    assert Map.has_key?(health, :service_unit_path)
  end

  test "the rendered service unit pins Allbert Home and SHELL" do
    unit = Service.render_unit("/opt/allbert/bin/allbert")
    assert unit =~ AllbertAssist.Paths.home()
    assert unit =~ "SHELL"
    assert unit =~ "allbert"

    case Service.platform() do
      :launchd -> assert unit =~ "WorkingDirectory" and unit =~ "serve"
      :systemd -> assert unit =~ "WorkingDirectory=" and unit =~ "ExecStart="
      :unsupported -> assert unit == ""
    end
  end

  test "install/uninstall commands use the modern per-user invocations" do
    case Service.platform() do
      :launchd ->
        assert [{"launchctl", ["bootstrap" | _]}] = Service.install_commands()
        assert [{"launchctl", ["bootout" | _]}] = Service.uninstall_commands()

      :systemd ->
        assert Enum.any?(Service.install_commands(), fn {c, a} ->
                 c == "systemctl" and "--user" in a
               end)

      :unsupported ->
        assert Service.install_commands() == []
    end
  end

  describe "service_control (command_execute, confirmation-gated)" do
    test "dry_run previews commands without executing" do
      assert {:ok, %{status: :completed, actions: [%{executed: false, commands: cmds}]}} =
               Runner.run(
                 "service_control",
                 %{operation: "install", dry_run: true},
                 %{user_id: "local"}
               )

      assert is_list(cmds)
    end

    test "the gate deny path executes nothing" do
      denied = %{user_id: "local", selected_action: "unregistered_boundary_probe"}

      assert {:ok, %{status: status, actions: [%{executed: false}]}} =
               ServiceControl.run(%{operation: "install"}, denied)

      assert status in [:denied, :error]
    end

    test "an unknown operation errors without touching the system" do
      assert {:ok, %{status: :error}} =
               Runner.run("service_control", %{operation: "frobnicate"}, %{user_id: "local"})
    end
  end
end
