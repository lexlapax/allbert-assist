defmodule Mix.Tasks.AllbertDispatcherTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime.Attach
  alias Mix.Tasks.Allbert, as: AllbertTask

  @moduletag :cli_dispatcher

  test "renders pure help and version through the unified CLI entry" do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    help = capture_io(fn -> assert :ok = AllbertTask.run(["--help"]) end)
    version = capture_io(fn -> assert :ok = AllbertTask.run(["version"]) end)

    assert Logger.level() == :warning
    assert help =~ "Allbert - local-first assistant workspace"
    assert help =~ "allbert search"
    assert version =~ "allbert #{Application.spec(:allbert_assist, :vsn)}"
  end

  test "raises with the unified CLI rendering for a nonzero result" do
    error =
      assert_raise Mix.Error, fn ->
        AllbertTask.run(["frobnicate"])
      end

    assert error.message =~ "unknown command"
    assert error.message =~ "allbert --help"
  end

  test "runtime commands attach to the source daemon instead of booting an embedded Home" do
    with_attach_home(fn ->
      start_supervised!(Attach.Server)
      previous_debug = System.get_env("ALLBERT_ATTACH_DEBUG")
      System.put_env("ALLBERT_ATTACH_DEBUG", "true")

      on_exit(fn -> restore_env("ALLBERT_ATTACH_DEBUG", previous_debug) end)

      stderr =
        capture_io(:stderr, fn ->
          stdout =
            capture_io(fn ->
              assert :ok =
                       AllbertTask.run([
                         "admin",
                         "settings",
                         "get",
                         "workspace.theme.mode"
                       ])
            end)

          send(self(), {:dispatcher_stdout, stdout})
        end)

      assert_receive {:dispatcher_stdout, stdout}
      assert stdout =~ "workspace.theme.mode="
      assert stderr =~ "allbert: served by the running daemon (attached)"
    end)
  end

  defp with_attach_home(fun) do
    original_paths = Application.get_env(:allbert_assist, Paths)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-mix-dispatcher-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)

    on_exit(fn ->
      restore_app_env(Paths, original_paths)
      File.rm_rf!(root)
    end)

    fun.()
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
