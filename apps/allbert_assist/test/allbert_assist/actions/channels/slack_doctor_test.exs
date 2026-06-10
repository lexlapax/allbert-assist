defmodule AllbertAssist.Actions.Channels.SlackDoctorTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Channels.SlackDoctor
  alias AllbertAssist.Channels.Slack.Doctor
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_plugins = PluginRegistry.registered_plugins()
    original_stub_result = Application.get_env(:allbert_assist, :slack_client_stub_result)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-slack-doctor-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    PluginRegistry.clear()
    assert {:ok, "allbert.slack"} = PluginRegistry.register_module(AllbertAssist.Plugins.Slack)
    Fragments.clear_cache()

    assert {:ok, _setting} =
             Settings.put("channels.slack.workspace_team_id", "T0123ABCDE", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.slack.allowed_channel_ids", ["C0123ABCDE"], %{audit?: false})

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_app_env(:slack_client_stub_result, original_stub_result)
      restore_plugins(original_plugins)
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
    assert response.doctor.socket_mode_status == :stub
    assert response.message =~ "Slack doctor"
    refute inspect(response) =~ "Bearer "

    assert {:ok, state} = Doctor.read_state()
    assert state["status"] == "ok"
    assert state["team"] == "Allbert Fixture"
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
