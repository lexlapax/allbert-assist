defmodule AllbertAssist.PublicProtocol.StdioGuardTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  test "stdio guard routes Logger output away from stdout" do
    root = temp_root("stdio-guard")
    File.mkdir_p!(root)
    stdout_path = Path.join(root, "stdout.log")
    stderr_path = Path.join(root, "stderr.log")
    app_ebin = Application.app_dir(:allbert_assist, "ebin")

    code =
      ~S"""
      AllbertAssist.PublicProtocol.StdioGuard.protect_stdout!()
      require Logger
      Logger.warning("stdio_guard_probe")
      Process.sleep(200)
      """

    script =
      [
        shell_quote(System.find_executable("elixir") || "elixir"),
        "-pa",
        shell_quote(app_ebin),
        "-e",
        shell_quote(code),
        ">",
        shell_quote(stdout_path),
        "2>",
        shell_quote(stderr_path)
      ]
      |> Enum.join(" ")

    try do
      assert {_output, 0} = System.cmd("sh", ["-c", script], stderr_to_stdout: true)

      assert File.read!(stdout_path) == ""
      assert File.read!(stderr_path) =~ "stdio_guard_probe"
    after
      File.rm_rf!(root)
    end
  end

  defp temp_root(prefix) do
    Path.join(System.tmp_dir!(), "allbert-#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
