defmodule AllbertAssist.Actions.Channels.MatrixDoctorTest do
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial

  import Plug.Conn

  alias AllbertAssist.Actions.Channels.MatrixDoctor
  alias AllbertAssist.Channels.Matrix.Doctor
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.Matrix, as: MatrixPlugin
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_plugins = PluginRegistry.registered_plugins()
    original_matrix_doctor_opts = Application.get_env(:allbert_assist, :matrix_doctor_client_opts)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-matrix-doctor-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, :matrix_doctor_client_opts, plug: {Req.Test, __MODULE__})

    PluginRegistry.clear()
    assert {:ok, "allbert.matrix"} = PluginRegistry.register_module(MatrixPlugin)
    Fragments.clear_cache()

    configure_matrix!()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_app_env(:matrix_doctor_client_opts, original_matrix_doctor_opts)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "returns and persists a redacted success envelope" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/_matrix/client/v3/account/whoami"
      assert get_req_header(conn, "authorization") == ["Bearer matrix-secret"]
      json(conn, %{"user_id" => "@allbert:example.com", "device_id" => "DEVICE"})
    end)

    assert {:ok, response} = MatrixDoctor.run(%{}, context())

    assert response.status == :completed
    assert response.doctor.status == :ok
    assert response.doctor.auth_ok
    assert response.doctor.endpoint_ok
    assert response.doctor.user_id == "@allbert:example.com"
    refute inspect(response) =~ "matrix-secret"

    assert {:ok, state} = Doctor.read_state()
    assert state["status"] == "ok"
    assert state["auth_ok"] == true
    assert state["user_id"] == "@allbert:example.com"
  end

  test "reports token rejection without leaking credentials" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/_matrix/client/v3/account/whoami"

      conn
      |> put_status(401)
      |> json(%{"errcode" => "M_UNKNOWN_TOKEN", "error" => "Unknown token"})
    end)

    assert {:ok, response} = MatrixDoctor.run(%{}, context())

    assert response.status == :completed
    assert response.doctor.status == :error
    refute response.doctor.auth_ok
    assert :token_rejected in response.diagnostics
    refute inspect(response) =~ "matrix-secret"
  end

  defp configure_matrix! do
    assert {:ok, _secret} =
             Secrets.put_secret("secret://channels/matrix/access_token", "matrix-secret", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put("channels.matrix.homeserver_url", "https://matrix.example.com", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put(
               "channels.matrix.access_token_ref",
               "secret://channels/matrix/access_token",
               %{
                 audit?: false
               }
             )

    assert {:ok, _setting} =
             Settings.put("channels.matrix.allowed_room_ids", ["!room:example.com"], %{
               audit?: false
             })
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
