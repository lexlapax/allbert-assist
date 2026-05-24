defmodule Mix.Tasks.Allbert.SandboxTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Sandbox, as: SandboxTask

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    home = temp_path("home")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.delete_env(:allbert_assist, Settings)

    on_exit(fn ->
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      Mix.Task.reenable("allbert.sandbox")
      File.rm_rf!(home)
    end)

    :ok
  end

  test "doctor prints disabled default posture" do
    output = capture_io(fn -> assert :ok = SandboxTask.run(["doctor"]) end)

    assert output =~ "Status: disabled"
    assert output =~ "Enabled: false"
    assert output =~ "Configured backend: auto"
    assert output =~ "Resolved backend: none"
    assert output =~ "sandbox/bundles"
    assert output =~ "sandbox/reports"
  end

  test "unknown subcommand raises usage" do
    assert_raise Mix.Error, ~r/mix allbert.sandbox doctor/, fn ->
      SandboxTask.run(["wat"])
    end
  end

  defp temp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "allbert-sandbox-task-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
