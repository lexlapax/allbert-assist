defmodule Mix.Tasks.Allbert.ExternalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.External, as: ExternalTask

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-external-task-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Mix.Task.reenable("allbert.external")
    configure_external()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "request creates a pending confirmation from CLI args" do
    output =
      capture_io(fn ->
        assert :ok =
                 ExternalTask.run([
                   "request",
                   "--url",
                   "https://example.com/status",
                   "--method",
                   "GET"
                 ])
      end)

    assert output =~ "External network request is ready for operator approval"
    assert output =~ "Nothing has executed yet"

    assert [pending] = Confirmations.list(status: :pending)
    assert pending["target_action"]["name"] == "external_network_request"
    assert pending["target_execution_mode"] == "req_http"
  end

  test "invalid command raises usage" do
    assert_raise Mix.Error, ~r/Usage:/, fn ->
      ExternalTask.run([])
    end
  end

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/status"], %{audit?: false})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
