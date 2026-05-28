defmodule Mix.Tasks.Allbert.ModelTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Model, as: ModelTask

  setup do
    on_exit(fn ->
      Mix.Task.reenable("allbert.model")
    end)

    :ok
  end

  test "lists provider and model profile metadata" do
    output =
      capture_io(fn ->
        assert :ok = ModelTask.run(["list"])
      end)

    assert output =~ "Active model profile: fast"
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
end
