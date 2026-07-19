defmodule Mix.Tasks.Allbert.ToolsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Tools, as: ToolsTask

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-tools-task-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      Mix.Task.reenable("allbert.tools")
      File.rm_rf!(root)
    end)

    :ok
  end

  test "find prints local tool candidates" do
    output =
      capture_io(fn ->
        assert :ok = ToolsTask.run(["find", "settings"])
      end)

    assert output =~ "Found "
    assert output =~ "list_settings"
    assert output =~ "usable_now=true"
    assert output =~ "requires=none"
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
