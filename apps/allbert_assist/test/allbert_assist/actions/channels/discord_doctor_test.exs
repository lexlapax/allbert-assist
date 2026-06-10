defmodule AllbertAssist.Actions.Channels.DiscordDoctorTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Channels.DiscordDoctor
  alias AllbertAssist.Channels.Discord.Doctor
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_plugins = PluginRegistry.registered_plugins()
    original_stub_result = Application.get_env(:allbert_assist, :discord_client_stub_result)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-discord-doctor-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    PluginRegistry.clear()

    assert {:ok, "allbert.discord"} =
             PluginRegistry.register_module(AllbertAssist.Plugins.Discord)

    Fragments.clear_cache()

    assert {:ok, _setting} =
             Settings.put("channels.discord.application_id", "123456", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.discord.allowed_guild_ids", ["987654321"], %{audit?: false})

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_app_env(:discord_client_stub_result, original_stub_result)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "returns and persists a redacted success envelope" do
    assert {:ok, response} = DiscordDoctor.run(%{}, context())

    assert response.status == :completed
    assert response.doctor.status == :ok
    assert response.doctor.auth_ok
    assert response.doctor.endpoint_ok
    assert response.doctor.gateway_status == :stub
    assert response.message =~ "Discord doctor"
    refute inspect(response) =~ "Bot "

    assert {:ok, state} = Doctor.read_state()
    assert state["status"] == "ok"
    assert state["bot_username"] == "allbert-fixture"
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

  defp context do
    %{
      actor: "local",
      channel: :test,
      request: %{channel: :test, user_id: "local", operator_id: "local"}
    }
  end

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
