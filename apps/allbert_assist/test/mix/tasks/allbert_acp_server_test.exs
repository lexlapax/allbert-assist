defmodule Mix.Tasks.AllbertAcpServerTest do
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.AcpServer

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-acp-server-task-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Mix.Task.reenable("allbert.acp_server")

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      Mix.Task.reenable("allbert.acp_server")
      File.rm_rf!(root)
    end)

    :ok
  end

  test "status reports Settings Central state and bounded ACP posture" do
    output =
      capture_io(fn ->
        assert :ok = AcpServer.run(["status"])
      end)

    assert output =~ "acp_server.enabled=false"
    assert output =~ "acp_stdio.enabled=false"
    assert output =~ "acp_protocol_version=1"
    assert output =~ "acp_transport=stdio_jsonrpc_ndjson"
    assert output =~ "acp_prompt_capabilities=text_only"
  end

  test "stdio subprocess emits only JSON-RPC lines on stdout" do
    root = temp_root("acp-stdio-subprocess")
    File.rm_rf!(root)
    File.mkdir_p!(root)

    stdout_path = Path.join(root, "stdout.log")
    stdout_snapshot_path = Path.join(root, "stdout.before_cleanup.log")
    stderr_path = Path.join(root, "stderr.log")
    stdin_path = Path.join(root, "stdin.jsonl")
    home = Path.join(root, "home")
    database_path = Path.join(home, "allbert_test.db")
    File.mkdir_p!(home)

    File.write!(
      stdin_path,
      ~s({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientInfo":{"name":"zed-fixture"}}}\n)
    )

    script = """
    set -e
    cd #{shell_quote(File.cwd!())}
    env MIX_ENV=test ALLBERT_HOME=#{shell_quote(home)} DATABASE_PATH=#{shell_quote(database_path)} \
      mix ecto.create --quiet
    env MIX_ENV=test ALLBERT_HOME=#{shell_quote(home)} DATABASE_PATH=#{shell_quote(database_path)} \
      mix ecto.migrate --quiet
    env MIX_ENV=test ALLBERT_HOME=#{shell_quote(home)} DATABASE_PATH=#{shell_quote(database_path)} \
      mix allbert.acp_server stdio < #{shell_quote(stdin_path)} > #{shell_quote(stdout_path)} 2> #{shell_quote(stderr_path)} &
    pid=$!
    i=0
    while [ "$i" -lt 80 ]; do
      if [ -s #{shell_quote(stdout_path)} ]; then
        break
      fi
      i=$((i + 1))
      sleep 0.25
    done
    cp #{shell_quote(stdout_path)} #{shell_quote(stdout_snapshot_path)}
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    test -s #{shell_quote(stdout_snapshot_path)}
    """

    try do
      assert {_output, 0} = System.cmd("sh", ["-c", script], stderr_to_stdout: true)

      stdout = File.read!(stdout_snapshot_path)
      lines = String.split(stdout, "\n", trim: true)

      assert [_line | _rest] = lines

      Enum.each(lines, fn line ->
        assert {:ok, %{"jsonrpc" => "2.0"}} = Jason.decode(line)
      end)

      refute stdout =~ "[warning]"
      refute stdout =~ "[error]"
    after
      File.rm_rf!(root)
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp temp_root(prefix) do
    Path.join(
      System.tmp_dir!(),
      "allbert-#{prefix}-#{System.pid()}-#{System.unique_integer([:positive])}"
    )
  end

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
