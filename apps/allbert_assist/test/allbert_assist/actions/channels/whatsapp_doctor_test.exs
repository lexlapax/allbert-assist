defmodule AllbertAssist.Actions.Channels.WhatsAppDoctorTest do
  use AllbertAssist.DataCase, async: false

  import Plug.Conn

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Channels.WhatsApp.Doctor
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.WhatsApp, as: WhatsAppPlugin
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_doctor_opts = Application.get_env(:allbert_assist, :whatsapp_doctor_client_opts)
    original_plugins = PluginRegistry.registered_plugins()

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-whatsapp-doctor-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    Application.put_env(:allbert_assist, :whatsapp_doctor_client_opts,
      plug: {Req.Test, __MODULE__}
    )

    PluginRegistry.clear()
    assert {:ok, "allbert.whatsapp"} = PluginRegistry.register_module(WhatsAppPlugin)
    Fragments.clear_cache()
    configure_whatsapp!()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_app_env(:whatsapp_doctor_client_opts, original_doctor_opts)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "doctor action returns redacted envelope and persists state" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v23.0/15551234567"
      assert get_req_header(conn, "authorization") == ["Bearer whatsapp-secret"]

      json(conn, %{
        "display_phone_number" => "+15551234567",
        "verified_name" => "Allbert Test",
        "quality_rating" => "GREEN"
      })
    end)

    assert {:ok, %{status: :completed} = response} =
             Runner.run("whatsapp_doctor", %{}, %{actor: "operator"})

    assert response.doctor.status == :ok
    assert response.doctor.auth_ok
    assert response.doctor.endpoint_ok
    assert response.doctor.phone_number_id == "[REDACTED_PHONE]"
    refute inspect(response) =~ "whatsapp-secret"
    refute inspect(response) =~ "+15551234567"

    assert {:ok, state} = Doctor.read_state()
    assert state["status"] == "ok"
    assert state["phone_number_id"] == "[REDACTED_PHONE]"
  end

  defp configure_whatsapp! do
    assert {:ok, _secret} =
             Secrets.put_secret("secret://channels/whatsapp/access_token", "whatsapp-secret", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put(
               "channels.whatsapp.access_token_ref",
               "secret://channels/whatsapp/access_token",
               %{
                 audit?: false
               }
             )

    assert {:ok, _setting} =
             Settings.put("channels.whatsapp.phone_number_id", "15551234567", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "channels.whatsapp.identity_map",
               [%{external_user_id: "+15550001111", user_id: "alice"}],
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put("channels.whatsapp.webhook_enabled", true, %{audit?: false})

    assert {:ok, _setting} = Settings.put("channels.whatsapp.enabled", true, %{audit?: false})
  end

  defp restore_plugins(original_plugins) do
    PluginRegistry.clear()
    Enum.each(original_plugins, &PluginRegistry.register_entry/1)
  end

  defp json(conn, body) do
    status = conn.status || 200

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
