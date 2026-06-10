defmodule Mix.Tasks.AllbertMcpServerTest do
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.McpServer

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-mcp-server-task-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Mix.Task.reenable("allbert.mcp_server")

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      Mix.Task.reenable("allbert.mcp_server")
      File.rm_rf!(root)
    end)

    :ok
  end

  test "status reports settings-central state and Allbert-owned HTTP ingress posture" do
    output =
      capture_io(fn ->
        assert :ok = McpServer.run(["status"])
      end)

    assert output =~ "mcp_server.enabled=false"
    assert output =~ "mcp_stdio.enabled=false"
    assert output =~ "mcp_protocol_versions=2025-06-18,2025-03-26"
    assert output =~ "mcp_http_transport=allbert_owned_ingress_only"
  end

  test "tools list prints only settings-allowlisted tools" do
    enable_mcp_stdio!()

    assert {:ok, _setting} =
             Settings.put("mcp_server.tools_enabled", ["direct_answer"], %{audit?: false})

    output =
      capture_io(fn ->
        assert :ok = McpServer.run(["tools", "list"])
      end)

    assert output =~ "direct_answer"
    refute output =~ "list_settings"
  end

  test "resources list prints only settings-allowlisted app namespaces" do
    enable_mcp_stdio!()

    assert {:ok, _setting} =
             Settings.put("mcp_server.memory_namespaces_enabled", ["stocksage.stocksage"], %{
               audit?: false
             })

    output =
      capture_io(fn ->
        assert :ok = McpServer.run(["resources", "list"])
      end)

    assert output =~ "allbert-memory://stocksage/stocksage"
    refute output =~ "identity"
  end

  test "stdio subprocess keeps stdout reserved for protocol frames" do
    root = temp_root("mcp-stdio-subprocess")
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
      ~s({"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"stdio-fixture","version":"0"}}}\n)
    )

    script = """
    set -e
    cd #{shell_quote(File.cwd!())}
    env MIX_ENV=test ALLBERT_HOME=#{shell_quote(home)} DATABASE_PATH=#{shell_quote(database_path)} \
      mix ecto.create --quiet
    env MIX_ENV=test ALLBERT_HOME=#{shell_quote(home)} DATABASE_PATH=#{shell_quote(database_path)} \
      mix ecto.migrate --quiet
    env MIX_ENV=test ALLBERT_HOME=#{shell_quote(home)} DATABASE_PATH=#{shell_quote(database_path)} \
      mix allbert.mcp_server stdio < #{shell_quote(stdin_path)} > #{shell_quote(stdout_path)} 2> #{shell_quote(stderr_path)} &
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

  defp enable_mcp_stdio! do
    assert {:ok, _setting} = Settings.put("mcp_server.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("mcp_server.stdio.enabled", true, %{audit?: false})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp temp_root(prefix) do
    Path.join(System.tmp_dir!(), "allbert-#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
