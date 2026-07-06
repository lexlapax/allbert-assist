defmodule AllbertAssist.Actions.Voice.EnsureVoiceTokenTest do
  @moduledoc """
  v0.62 M8.15: `ensure_voice_token` runs the local voice runtime authority-token
  ensure on-spine through the Runner (PermissionGate + audit). First use is a
  mutation (generates + persists the token), so it may not stay off-spine.
  """
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Voice.LocalRuntime.Auth

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-ensure-voice-token-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Settings.put("permissions.voice_local_runtime_manage", "allowed", %{audit?: false})

    on_exit(fn ->
      restore_app_env(Paths, original_paths)
      restore_app_env(Settings, original_settings)
      File.rm_rf(home)
    end)

    :ok
  end

  test "ensures and persists the token on-spine, idempotently, without leaking it into metadata" do
    refute File.exists?(Auth.token_path())

    assert {:ok, response} = Runner.run("ensure_voice_token", %{}, ctx())

    assert response.status == :completed
    assert response.permission_decision.permission == :voice_local_runtime_manage
    assert response.permission_decision.decision == :allowed
    assert is_binary(response.token) and response.token != ""
    assert File.exists?(Auth.token_path())
    assert {:ok, response.token} == Auth.read_token()

    # Raw token is renderable from the in-memory response but redacted in the
    # action metadata that flows to logs/audit.
    [action] = response.actions
    assert action.voice_local_runtime.token == "[REDACTED]"
    refute inspect(action) =~ response.token

    # Idempotent: a second ensure returns the same persisted token.
    assert {:ok, second} = Runner.run("ensure_voice_token", %{}, ctx())
    assert second.token == response.token
  end

  test "honors Security Central denial and does not persist a token" do
    assert {:ok, _setting} =
             Settings.put("permissions.voice_local_runtime_manage", "denied", %{audit?: false})

    assert {:ok, response} = Runner.run("ensure_voice_token", %{}, ctx())

    assert response.status == :denied
    assert response.error == :permission_denied
    assert response.permission_decision.decision == :denied
    refute Map.has_key?(response, :token)
    refute File.exists?(Auth.token_path())
  end

  defp ctx, do: %{actor: "operator", user_id: "operator", channel: :cli}

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
