defmodule AllbertAssist.CLI.Areas.NotesTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.CLI.Areas.Notes, as: Area
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    home = Path.join(System.tmp_dir!(), "allbert-notes-cli-#{System.unique_integer([:positive])}")
    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths)
      restore_env(Settings, original_settings)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "usage names the dispatchable notes commands" do
    assert {usage, 2} = Area.dispatch(["help"])
    assert usage =~ "allbert.notes set-root PATH"
    assert usage =~ "allbert.notes show"
  end

  test "set-root connects an existing directory and show reads it back", %{home: home} do
    dir = Path.join(home, "launch-notes")
    File.mkdir_p!(dir)

    assert {out, 0} = Area.dispatch(["set-root", dir])
    assert out =~ "Notes root set to"
    assert out =~ dir

    assert {shown, 0} = Area.dispatch(["show"])
    assert shown =~ dir
  end

  test "set-root fails closed (exit 1) on a missing directory", %{home: home} do
    missing = Path.join(home, "does-not-exist")
    assert {out, 1} = Area.dispatch(["set-root", missing])
    assert out =~ "could not set the notes root"
  end

  test "set-root without a PATH is an argument error", %{home: _home} do
    assert {out, 1} = Area.dispatch(["set-root"])
    assert out =~ "requires a PATH"
  end

  test "unknown subcommand is an argument error" do
    assert {out, 1} = Area.dispatch(["frobnicate"])
    assert out =~ "Unknown notes command"
  end

  defp restore_env(_module, nil), do: :ok
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
