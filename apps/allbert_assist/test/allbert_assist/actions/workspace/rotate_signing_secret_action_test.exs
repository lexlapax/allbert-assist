defmodule AllbertAssist.Actions.Workspace.RotateSigningSecretActionTest do
  @moduledoc """
  v0.62 M8.19: workspace signing-secret rotation runs on-spine through Runner.
  """
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace.Fragment.SigningSecret

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-rotate-signing-secret-action-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths)
      restore_env(Settings, original_settings)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "rotates the signing secret on-spine without exposing raw key material", %{home: home} do
    assert {:ok, response} = Runner.run("rotate_workspace_signing_secret", %{}, ctx())

    assert response.status == :completed
    assert response.permission_decision.permission == :settings_secret_write
    assert response.permission_decision.decision == :allowed
    assert response.rotation.path == Path.join([home, "workspace", "secrets", "signing_secret"])
    assert response.rotation.overlap_seconds == 60

    {:ok, secret} = SigningSecret.read()
    assert SigningSecret.valid?(secret)
    refute inspect(response.actions) =~ secret
  end

  defp ctx, do: %{actor: "operator", user_id: "operator", channel: :cli}

  defp restore_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
