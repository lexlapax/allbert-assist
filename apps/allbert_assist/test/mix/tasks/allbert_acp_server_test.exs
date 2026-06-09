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
        "allbert-acp-server-task-#{System.unique_integer([:positive])}"
      )

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

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
