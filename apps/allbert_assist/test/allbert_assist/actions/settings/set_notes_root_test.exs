defmodule AllbertAssist.Actions.Settings.SetNotesRootTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Settings.SetNotesRoot
  alias AllbertAssist.Settings

  @context %{request: %{operator_id: "local", channel: :test, input_signal_id: "sig"}}

  setup do
    original_settings = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-set-notes-root-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      if original_settings,
        do: Application.put_env(:allbert_assist, Settings, original_settings),
        else: Application.delete_env(:allbert_assist, Settings)

      File.rm_rf!(root)
    end)

    :ok
  end

  test "connects an existing directory as the notes root (config-free)" do
    dir = Path.join(System.tmp_dir!(), "notes-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:ok, response} = SetNotesRoot.run(%{path: dir}, @context)
    assert response.status == :completed
    assert response.message =~ dir
    assert response.setting.key == "apps.notes_files.notes_root"

    # The write lands on the single safe key and reads back.
    assert {:ok, ^dir} = Settings.get("apps.notes_files.notes_root")
  end

  test "fails closed on a path that is not an existing directory" do
    missing = Path.join(System.tmp_dir!(), "nope-#{System.unique_integer([:positive])}")

    assert {:ok, response} = SetNotesRoot.run(%{path: missing}, @context)
    assert response.status == :denied
    assert response.message =~ "could not set the notes root"
  end

  test "fails closed on a path that is a file, not a directory" do
    file = Path.join(System.tmp_dir!(), "notes-file-#{System.unique_integer([:positive])}.md")
    File.write!(file, "# not a dir")
    on_exit(fn -> File.rm_rf!(file) end)

    assert {:ok, response} = SetNotesRoot.run(%{path: file}, @context)
    assert response.status == :denied
  end

  test "rejects an empty path" do
    assert {:ok, response} = SetNotesRoot.run(%{path: "   "}, @context)
    assert response.status == :denied
  end
end
