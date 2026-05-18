defmodule Mix.Tasks.Allbert.WorkspaceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Paths
  alias AllbertAssist.Workspace.Fragment.SigningSecret
  alias Mix.Tasks.Allbert.Workspace, as: WorkspaceTask

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(System.tmp_dir!(), "allbert-workspace-task-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: home)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      Mix.Task.reenable("allbert.workspace")
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "rotates the workspace fragment signing secret", %{home: home} do
    output =
      capture_io(fn ->
        assert :ok = WorkspaceTask.run(["rotate-signing-secret"])
      end)

    assert output =~ "Rotated workspace fragment signing secret."
    assert output =~ "Fingerprint:"
    assert output =~ Path.join([home, "workspace", "secrets", "signing_secret"])

    {:ok, secret} = SigningSecret.read()
    assert SigningSecret.valid?(secret)
    refute output =~ secret
  end

  test "unknown commands raise usage" do
    assert_raise Mix.Error, ~r/allbert.workspace rotate-signing-secret/, fn ->
      WorkspaceTask.run(["unknown"])
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
