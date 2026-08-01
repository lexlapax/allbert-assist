defmodule Mix.Tasks.AllbertDispatcherTest do
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.CLI
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Attach
  alias Mix.Tasks.Allbert, as: AllbertTask

  @moduletag :cli_dispatcher

  test "source daemon logging defaults to info and honors the validated override" do
    previous_level = Logger.level()
    previous_primary_level = :logger.get_primary_config() |> Map.fetch!(:level)
    previous_config_level = Application.get_env(:logger, :level)
    previous_override = System.get_env("ALLBERT_LOG_LEVEL")

    on_exit(fn ->
      restore_logger_config(previous_config_level)
      Logger.configure(level: previous_level)
      _result = :logger.set_primary_config(:level, previous_primary_level)
      restore_env("ALLBERT_LOG_LEVEL", previous_override)
    end)

    System.delete_env("ALLBERT_LOG_LEVEL")
    Logger.configure(level: :debug)
    assert :ok = CLI.configure_daemon_logging()
    assert Logger.level() == :info
    assert Application.get_env(:logger, :level) == :info
    assert :logger.get_primary_config() |> Map.fetch!(:level) == :info

    System.put_env("ALLBERT_LOG_LEVEL", "debug")
    assert :ok = CLI.configure_daemon_logging()
    assert Logger.level() == :debug
    assert Application.get_env(:logger, :level) == :debug
    assert :logger.get_primary_config() |> Map.fetch!(:level) == :debug

    System.put_env("ALLBERT_LOG_LEVEL", "invalid")
    assert :ok = CLI.configure_daemon_logging()
    assert Logger.level() == :info
    assert Application.get_env(:logger, :level) == :info
    assert :logger.get_primary_config() |> Map.fetch!(:level) == :info
  end

  if System.get_env("ALLBERT_SOURCE_DAEMON_LOG_INTEGRATION") != "1" do
    @tag skip: "set ALLBERT_SOURCE_DAEMON_LOG_INTEGRATION=1 for the source-daemon subprocess row"
  end

  test "source daemon keeps lifecycle info and excludes dev debug query binds" do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-source-daemon-log-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    home = Path.join(root, "home")
    log_path = Path.join(root, "source-daemon.log")
    port = available_port()
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(root) end)

    env = source_daemon_env(home, log_path, port)
    mix = System.find_executable("mix") || flunk("mix executable not found")

    {migration_output, 0} =
      System.cmd(mix, ["allbert.ecto.migrate", "--quiet"],
        cd: repo_root(),
        env: env,
        stderr_to_stdout: true
      )

    {serve_output, serve_status} =
      System.cmd("/bin/bash", ["--noprofile", "--norc", "-c", source_daemon_script()],
        cd: repo_root(),
        env: [{"SOURCE_MIX", mix} | env],
        stderr_to_stdout: true
      )

    assert serve_status == 0, migration_output <> serve_output

    log = File.read!(log_path)
    assert log =~ "[info] writer lock acquired"
    assert log =~ "[info] allbert signal allbert.plugin.registered"
    refute log =~ "[debug]"
    refute log =~ "QUERY OK"
  end

  test "renders pure help and version through the unified CLI entry" do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    help = capture_io(fn -> assert :ok = AllbertTask.run(["--help"]) end)
    version = capture_io(fn -> assert :ok = AllbertTask.run(["version"]) end)

    assert Logger.level() == :warning
    assert help =~ "Allbert - local-first assistant workspace"
    assert help =~ "allbert search"
    assert version =~ "allbert #{Application.spec(:allbert_assist, :vsn)}"
  end

  test "raises with the unified CLI rendering for a nonzero result" do
    error =
      assert_raise Mix.Error, fn ->
        AllbertTask.run(["frobnicate"])
      end

    assert error.message =~ "unknown command"
    assert error.message =~ "allbert --help"
  end

  test "runtime commands attach to the source daemon instead of booting an embedded Home" do
    with_attach_home(fn ->
      start_supervised!(Attach.Server)
      previous_debug = System.get_env("ALLBERT_ATTACH_DEBUG")
      System.put_env("ALLBERT_ATTACH_DEBUG", "true")

      on_exit(fn -> restore_env("ALLBERT_ATTACH_DEBUG", previous_debug) end)

      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              assert :ok =
                       AllbertTask.run([
                         "admin",
                         "settings",
                         "get",
                         "workspace.theme.mode"
                       ])
            end)

          send(self(), {:dispatcher_stdout, stdout})
        end)

      assert_receive {:dispatcher_stdout, stdout}
      assert stdout =~ "workspace.theme.mode="
      assert stderr =~ "allbert: served by the running daemon (attached)"
    end)
  end

  defp with_attach_home(fun) do
    original_paths = Application.get_env(:allbert_assist, Paths)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-mix-dispatcher-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)

    on_exit(fn ->
      restore_app_env(Paths, original_paths)
      File.rm_rf!(root)
    end)

    fun.()
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_logger_config(nil), do: Application.delete_env(:logger, :level)
  defp restore_logger_config(level), do: Application.put_env(:logger, :level, level)

  defp available_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp source_daemon_env(home, log_path, port) do
    [
      {"ALLBERT_HOME", home},
      {"ALLBERT_HOME_DIR", home},
      {"ALLBERT_LOG_LEVEL", nil},
      {"ALLBERT_SETTINGS_MASTER_KEY", 32 |> :crypto.strong_rand_bytes() |> Base.encode64()},
      {"MIX_ENV", "dev"},
      {"SOURCE_DAEMON_LOG", log_path},
      {"SOURCE_DAEMON_PORT", Integer.to_string(port)}
    ]
  end

  defp source_daemon_script do
    """
    set -Eeuo pipefail
    daemon_pid=
    cleanup() {
      if test -n "${daemon_pid:-}"; then
        kill "$daemon_pid" 2>/dev/null || true
        wait "$daemon_pid" 2>/dev/null || true
      fi
    }
    trap cleanup EXIT INT TERM

    PORT="$SOURCE_DAEMON_PORT" "$SOURCE_MIX" allbert serve >"$SOURCE_DAEMON_LOG" 2>&1 &
    daemon_pid=$!
    ready=false
    for ((attempt=1; attempt<=90; attempt++)); do
      if curl -fsS --max-time 2 "http://127.0.0.1:$SOURCE_DAEMON_PORT/health" 2>/dev/null |
           grep -q '"status":"ok"'; then
        ready=true
        break
      fi
      if ! kill -0 "$daemon_pid" 2>/dev/null; then
        break
      fi
      sleep 0.2
    done
    test "$ready" = true
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
    daemon_pid=
    """
  end

  defp repo_root, do: Path.expand("../../../../..", __DIR__)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
