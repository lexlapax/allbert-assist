defmodule AllbertAssist.Channels.EmailTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Email.Adapter
  alias AllbertAssist.Channels.Email.Parser
  alias AllbertAssist.Channels.Email.SmtpClient
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  defmodule FakeImapClient do
    def connect(_host, _port, opts), do: {:ok, %{fake_name: Keyword.fetch!(opts, :fake_name)}}
    def login(conn, _username, _password), do: {:ok, conn}
    def select_mailbox(conn, _mailbox), do: {:ok, conn}

    def search_unseen(conn) do
      uids = Agent.get(conn.fake_name, fn state -> Map.keys(state.messages) end)
      {:ok, uids}
    end

    def fetch_message(conn, uid) do
      Agent.get(conn.fake_name, fn state -> Map.fetch(state.messages, uid) end)
      |> case do
        {:ok, message} -> {:ok, message}
        :error -> {:error, :not_found}
      end
    end

    def mark_seen(conn, uid) do
      Agent.update(conn.fake_name, fn state -> update_in(state.seen, &[uid | &1]) end)
      :ok
    end

    def logout(_conn), do: :ok
  end

  defmodule FailingImapClient do
    def connect(_host, _port, _opts), do: {:error, :timeout}
  end

  setup do
    original_env = Map.new(["ALLBERT_HOME", "ALLBERT_HOME_DIR"], &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(Map.keys(original_env), &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home =
      Path.join(System.tmp_dir!(), "allbert-email-test-#{System.unique_integer([:positive])}")

    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
    end)

    :ok
  end

  describe "parser" do
    test "parses plain text email" do
      assert {:ok, fields} = Parser.parse_email(plain_email())
      assert fields.from_address == "alice@example.com"
      assert fields.message_id == "msg-1@example.com"
      assert fields.subject == "Hello"
      assert fields.text_body =~ "Hi Allbert"
      assert fields.attachment_count == 0
    end

    test "parses multipart alternative text part" do
      assert {:ok, fields} = Parser.parse_email(multipart_email())
      assert fields.text_body =~ "Plain hello"
      assert fields.html_body =~ "<p>HTML hello</p>"
    end

    test "detects typed confirmation commands before quoted reply" do
      assert Parser.detect_command("ALLBERT:APPROVE:conf_123\n> quoted") ==
               {:command, "approve", "conf_123"}

      assert Parser.detect_command("deny conf_456\nOn Yesterday, someone wrote:") ==
               {:command, "deny", "conf_456"}

      assert Parser.detect_command("hello") == :regular_text
    end
  end

  describe "SMTP client" do
    test "formats bounded plain text messages and strips header injection" do
      message =
        SmtpClient.format_message(
          "allbert@example.com",
          "alice@example.com",
          "Re: Hi\r\nBcc: bad@example.com",
          "body",
          in_reply_to: "msg-1@example.com",
          from_name: "Allbert"
        )

      assert message =~ "From: Allbert <allbert@example.com>"
      assert message =~ "To: alice@example.com"
      assert message =~ "Subject: Re: Hi  Bcc: bad@example.com"
      assert message =~ "In-Reply-To: msg-1@example.com"
      assert message =~ "\r\n\r\nbody"
    end
  end

  describe "adapter" do
    test "starts idle when disabled" do
      server = :"email-disabled-#{System.unique_integer([:positive])}"
      start_supervised!({Adapter, name: server, auto_poll?: false})

      assert Adapter.poll_once(server) == {:error, :disabled}
    end

    test "poll_once inserts received events and marks messages seen" do
      configure_email!()

      fake =
        start_fake_imap!(%{"1" => plain_email(), "2" => multipart_email("msg-2@example.com")})

      server = :"email-poll-#{System.unique_integer([:positive])}"
      start_email_server!(server, fake)

      assert {:ok, %{processed: 2, duplicates: 0, rejected: 0, failed: 0}} =
               Adapter.poll_once(server)

      assert Channels.get_event_by_external_id("email", "msg-1@example.com").direction ==
               "inbound"

      assert Channels.get_event_by_external_id("email", "msg-2@example.com").external_user_id ==
               "alice@example.com"

      assert Agent.get(fake, &Enum.sort(&1.seen)) == ["1", "2"]
    end

    test "dedupes replayed Message-ID values and still marks seen" do
      configure_email!()
      fake = start_fake_imap!(%{"1" => plain_email()})
      server = :"email-duplicate-#{System.unique_integer([:positive])}"
      start_email_server!(server, fake)

      assert {:ok, %{processed: 1}} = Adapter.poll_once(server)
      assert {:ok, %{duplicates: 1}} = Adapter.poll_once(server)
      assert Agent.get(fake, &length(&1.seen)) == 2
    end

    test "backs off on IMAP connection errors" do
      configure_email!()
      server = :"email-error-#{System.unique_integer([:positive])}"

      start_supervised!(
        {Adapter,
         name: server,
         auto_poll?: false,
         imap_client: FailingImapClient,
         client_opts: [fake_name: :unused]}
      )

      assert {:error, :timeout} = Adapter.poll_once(server)
    end
  end

  defp configure_email! do
    assert {:ok, _secret} =
             Secrets.put_secret("secret://channels/email/imap_password", "imap-pass", %{
               audit?: false
             })

    assert {:ok, _secret} =
             Secrets.put_secret("secret://channels/email/smtp_password", "smtp-pass", %{
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

    assert {:ok, _setting} = Settings.put("channels.email.enabled", true, %{audit?: false})
  end

  defp start_fake_imap!(messages) do
    name = :"fake-imap-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start_link(fn -> %{messages: messages, seen: []} end, name: name)
    on_exit(fn -> if Process.whereis(name), do: Agent.stop(name) end)
    name
  end

  defp start_email_server!(server, fake_name) do
    start_supervised!(
      {Adapter,
       name: server,
       auto_poll?: false,
       imap_client: FakeImapClient,
       client_opts: [fake_name: fake_name]}
    )
  end

  defp plain_email(message_id \\ "msg-1@example.com") do
    """
    From: Alice <alice@example.com>
    To: allbert@example.com
    Subject: Hello
    Message-ID: <#{message_id}>
    Content-Type: text/plain; charset=utf-8

    Hi Allbert
    """
  end

  defp multipart_email(message_id \\ "msg-2@example.com") do
    """
    From: Alice <alice@example.com>
    To: allbert@example.com
    Subject: Multipart
    Message-ID: <#{message_id}>
    Content-Type: multipart/alternative; boundary="abc"

    --abc
    Content-Type: text/plain; charset=utf-8

    Plain hello
    --abc
    Content-Type: text/html; charset=utf-8

    <p>HTML hello</p>
    --abc--
    """
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
