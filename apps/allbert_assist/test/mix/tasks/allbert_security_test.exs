defmodule Mix.Tasks.Allbert.SecurityTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Security, as: SecurityTask

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-security-task-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      Mix.Task.reenable("allbert.security")
      File.rm_rf!(root)
    end)

    :ok
  end

  test "prints security status without raw secret references" do
    output = capture_io(fn -> assert :ok = SecurityTask.run(["status"]) end)

    assert output =~ "Security Central"
    assert output =~ "command_execute"
    assert output =~ "Safety floors:"
    assert output =~ "Secrets:"
    assert output =~ "Settings versions:"
    assert output =~ "status=ok"
    assert output =~ "Future boundaries:"
    refute output =~ "secret://"
  end

  test "rejects invalid usage" do
    assert_raise Mix.Error, ~r/mix allbert.security status/, fn ->
      SecurityTask.run(["wat"])
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
