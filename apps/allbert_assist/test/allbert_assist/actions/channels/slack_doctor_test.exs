defmodule AllbertSlack.Actions.DoctorTest do
  use AllbertAssist.DataCase, async: false

  import AllbertAssist.TestSupport.ActionEnvelopeAssertions

  alias AllbertSlack.Actions.Doctor
  alias AllbertSlack.Doctor
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_stub_result = Application.get_env(:allbert_assist, :slack_client_stub_result)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-slack-doctor-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    Fragments.clear_cache()

    assert {:ok, _setting} =
             Settings.put(
               "channels.slack.workspace_team_id",
               "T0123ABCDE",
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "channels.slack.allowed_channel_ids",
               ["C0123ABCDE"],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_app_env(:slack_client_stub_result, original_stub_result)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "returns and persists a redacted success envelope" do
    assert {:ok, response} = SlackDoctor.run(%{}, context())

    assert response.status == :completed
    assert response.doctor.status == :ok
    assert response.doctor.auth_ok
    assert response.doctor.endpoint_ok
    # Live transport status from the (disabled-in-test) adapter, not a constant.
    assert response.doctor.socket_mode_status == :disabled
    assert response.doctor.missing_scopes == []
    assert "chat:write" in response.doctor.granted_scopes
    refute :missing_bot_scopes in response.doctor.diagnostics
    assert response.message =~ "Slack doctor"
    refute inspect(response) =~ "Bearer "

    assert_channel_envelope(response,
      name: "slack_doctor",
      message:
        "Slack doctor: status=ok auth_ok=true endpoint_ok=true socket_mode=disabled " <>
          "team=Allbert Fixture",
      status: :completed,
      action_status: :completed,
      decision: :allowed,
      diagnostics: [],
      metadata: %{
        doctor_status: :ok,
        auth_ok: true,
        endpoint_ok: true,
        socket_mode_status: :disabled,
        diagnostics: []
      }
    )

    assert {:ok, state} = Doctor.read_state()
    assert state["status"] == "ok"
    assert state["team"] == "Allbert Fixture"
    assert state["socket_mode_status"] == "disabled"
  end

  test "flags missing bot scopes as a warning without leaking the token" do
    assert {:ok, result} =
             Doctor.diagnose(client_opts: [mode: :stub, stub_scopes: ["chat:write"]])

    assert result.status == :warning
    assert "app_mentions:read" in result.missing_scopes
    assert "im:history" in result.missing_scopes
    assert :missing_bot_scopes in result.diagnostics
    refute inspect(result) =~ "Bearer "
  end

  test "normalizes injected live socket status without leaking internal reasons" do
    assert {:ok, running} =
             Doctor.diagnose(client_opts: [mode: :stub], transport_status: :running)

    assert running.socket_mode_status == :running

    assert {:ok, errored} =
             Doctor.diagnose(client_opts: [mode: :stub], transport_status: {:error, :boom})

    assert errored.socket_mode_status == :error
    refute inspect(errored) =~ "boom"
  end

  test "reports token rejection without leaking credentials" do
    Application.put_env(:allbert_assist, :slack_client_stub_result, :unauthorized)

    assert {:ok, response} = SlackDoctor.run(%{}, context())

    assert response.status == :completed
    assert response.doctor.status == :error
    assert :token_rejected in response.diagnostics
    refute inspect(response) =~ "Authorization:"
    refute inspect(response) =~ "Bearer "
  end

  test "preserves the exact denial envelope before diagnostics run" do
    assert {:ok, response} = SlackDoctor.run(%{}, denied_context())

    assert response.doctor == %{}

    assert_channel_envelope(response,
      name: "slack_doctor",
      message: denied_message(),
      status: :denied,
      action_status: :denied,
      decision: :denied,
      diagnostics: [],
      metadata: %{error: :permission_denied}
    )
  end

  defp context do
    %{
      actor: "local",
      channel: :test,
      request: %{channel: :test, user_id: "local", operator_id: "local"}
    }
  end

  defp denied_context, do: %{selected_action: "unregistered_boundary_probe"}

  defp denied_message,
    do: "Unknown or unregistered action boundary: \"unregistered_boundary_probe\"."

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
