defmodule AllbertAssist.Actions.Channels.EmailDoctorTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Channels.EmailDoctor
  alias AllbertAssist.Channels.Email.Doctor
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.TestSupport.ShippedRegistries

  defmodule FakeImapClient do
    def connect(_host, _port, opts), do: {:ok, %{opts: opts}}
    def login(conn, _username, "imap-secret"), do: {:ok, conn}
    def login(_conn, _username, _password), do: {:error, {:imap_command_failed, "NO"}}
    def select_mailbox(conn, _mailbox), do: {:ok, conn}
    def search_unseen(conn), do: {:ok, Keyword.get(conn.opts, :uids, [])}
    def logout(_conn), do: :ok
  end

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_imap_client = Application.get_env(:allbert_assist, :email_doctor_imap_client)
    original_imap_opts = Application.get_env(:allbert_assist, :email_doctor_imap_opts)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-email-doctor-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, :email_doctor_imap_client, FakeImapClient)
    Application.put_env(:allbert_assist, :email_doctor_imap_opts, uids: ["1"])

    PluginRegistry.clear()
    assert {:ok, "allbert.email"} = PluginRegistry.register_module(AllbertAssist.Plugins.Email)
    Fragments.clear_cache()

    configure_email!()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_app_env(:email_doctor_imap_client, original_imap_client)
      restore_app_env(:email_doctor_imap_opts, original_imap_opts)
      ShippedRegistries.restore!()
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "returns and persists a redacted success envelope" do
    assert {:ok, response} = EmailDoctor.run(%{}, context())

    assert response.status == :completed
    assert response.doctor.status == :ok
    assert response.doctor.auth_ok
    assert response.doctor.endpoint_ok
    assert response.doctor.imap_endpoint_ok
    assert response.doctor.smtp_endpoint_ok
    assert response.doctor.poller_status in [:disabled, :not_started]
    assert response.message =~ "Email doctor"
    refute inspect(response) =~ "imap-secret"
    refute inspect(response) =~ "smtp-secret"

    assert {:ok, state} = Doctor.read_state()
    assert state["status"] == "ok"
    assert state["imap_endpoint_ok"] == true
    assert state["smtp_endpoint_ok"] == true
  end

  test "reports IMAP login rejection without leaking credentials" do
    assert {:ok, _secret} =
             Secrets.put_secret("secret://channels/email/imap_password", "bad-secret", %{
               audit?: false
             })

    assert {:ok, response} = EmailDoctor.run(%{}, context())

    assert response.status == :completed
    assert response.doctor.status == :error
    assert :imap_login_or_mailbox_failed in response.diagnostics
    refute inspect(response) =~ "bad-secret"
  end

  defp configure_email! do
    assert {:ok, _secret} =
             Secrets.put_secret("secret://channels/email/imap_password", "imap-secret", %{
               audit?: false
             })

    assert {:ok, _secret} =
             Secrets.put_secret("secret://channels/email/smtp_password", "smtp-secret", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put("channels.email.imap_host", "imap.example.com", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.email.smtp_host", "smtp.example.com", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.email.imap_username", "alice", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.email.smtp_username", "alice", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("channels.email.from_address", "allbert@example.com", %{audit?: false})
  end

  defp context do
    %{
      actor: "local",
      channel: :test,
      request: %{channel: :test, user_id: "local", operator_id: "local"}
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
