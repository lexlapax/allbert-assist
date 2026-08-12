defmodule AllbertDiscord.Actions.DoctorTest do
  use AllbertAssist.DataCase, async: false

  import AllbertAssist.TestSupport.ActionEnvelopeAssertions

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertDiscord.Actions.Doctor, as: DiscordDoctor
  alias AllbertDiscord.Doctor

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_stub_result = Application.get_env(:allbert_assist, :discord_client_stub_result)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-discord-doctor-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    Fragments.clear_cache()

    assert {:ok, _setting} =
             Settings.put(
               "channels.discord.application_id",
               "123456",
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "channels.discord.allowed_guild_ids",
               ["987654321"],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_app_env(:discord_client_stub_result, original_stub_result)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "returns and persists a redacted success envelope" do
    assert {:ok, _setting} =
             Settings.put(
               "channels.discord.gateway_intents",
               ["guild_messages", "direct_messages", "message_content"],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, response} = DiscordDoctor.run(%{}, context())

    assert response.status == :completed
    assert response.doctor.status == :ok
    assert response.doctor.auth_ok
    assert response.doctor.endpoint_ok
    # Live transport status from the (disabled-in-test) adapter, not a constant.
    assert response.doctor.gateway_status == :disabled
    assert response.doctor.message_content_intent == true
    refute :missing_message_content_intent in response.doctor.diagnostics
    assert response.message =~ "Discord doctor"
    refute inspect(response) =~ "Bot "

    assert_channel_envelope(response,
      name: "discord_doctor",
      message:
        "Discord doctor: status=ok auth_ok=true endpoint_ok=true gateway=disabled " <>
          "bot=allbert-fixture",
      status: :completed,
      action_status: :completed,
      decision: :allowed,
      diagnostics: [],
      metadata: %{
        doctor_status: :ok,
        auth_ok: true,
        endpoint_ok: true,
        gateway_status: :disabled,
        diagnostics: []
      }
    )

    assert {:ok, state} = Doctor.read_state()
    assert state["status"] == "ok"
    assert state["bot_username"] == "allbert-fixture"
    assert state["gateway_status"] == "disabled"
  end

  test "flags a missing message_content gateway intent as a warning" do
    assert {:ok, _setting} =
             Settings.put(
               "channels.discord.gateway_intents",
               ["guild_messages", "direct_messages"],
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, response} = DiscordDoctor.run(%{}, context())

    assert response.status == :completed
    assert response.doctor.status == :warning
    assert response.doctor.message_content_intent == false
    assert :missing_message_content_intent in response.doctor.diagnostics
  end

  test "normalizes injected live gateway status without leaking internal reasons" do
    assert {:ok, running} = Doctor.diagnose(transport_status: :running)
    assert running.gateway_status == :running

    assert {:ok, errored} = Doctor.diagnose(transport_status: {:error, :boom})
    assert errored.gateway_status == :error
    refute inspect(errored) =~ "boom"
  end

  test "reports token rejection without leaking credentials" do
    Application.put_env(:allbert_assist, :discord_client_stub_result, :unauthorized)

    assert {:ok, response} = DiscordDoctor.run(%{}, context())

    assert response.status == :completed
    assert response.doctor.status == :error
    assert :token_rejected in response.diagnostics
    refute inspect(response) =~ "Authorization:"
    refute inspect(response) =~ "Bot "
  end

  test "preserves the exact denial envelope before diagnostics run" do
    assert {:ok, response} = DiscordDoctor.run(%{}, denied_context())

    assert response.doctor == %{}

    assert_channel_envelope(response,
      name: "discord_doctor",
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
