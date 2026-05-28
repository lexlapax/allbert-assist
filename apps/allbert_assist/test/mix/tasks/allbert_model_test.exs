defmodule Mix.Tasks.Allbert.ModelTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Model, as: ModelTask

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    root = temp_path("settings")

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
      Mix.Task.reenable("allbert.model")
    end)

    :ok
  end

  test "lists provider and model profile metadata" do
    output =
      capture_io(fn ->
        assert :ok = ModelTask.run(["list"])
      end)

    assert output =~ "Active model profile: local"
    assert output =~ "local_ollama"
    assert output =~ "endpoint_kind=local_endpoint"
    assert output =~ "llama3.2:3b"
  end

  test "uses model profile and can enable model-assisted intent" do
    output =
      capture_io(fn ->
        assert :ok = ModelTask.run(["use", "local", "--enable-assist"])
      end)

    assert output =~ "Active model profile set to local"
    assert {:ok, "local"} = Settings.get("intent.model_profile")
    assert {:ok, true} = Settings.get("intent.model_assist_enabled")
  end

  test "doctors credentialed model profile without configured credential" do
    output =
      capture_io(fn ->
        assert :ok = ModelTask.run(["doctor", "fast"])
      end)

    assert output =~ "endpoint_kind=credentialed_remote"
    assert output =~ "credential_ok=false"
    assert output =~ "diagnostic=credential_missing"
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-model-task-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
