defmodule AllbertAssist.Channels.EmailTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Email.Adapter
  alias AllbertAssist.Channels.Email.Parser
  alias AllbertAssist.Channels.Email.Renderer
  alias AllbertAssist.Channels.Email.SmtpClient
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ConversationMessageRef
  alias AllbertAssist.Objectives
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.TestSupport.ShippedRegistries
  alias AllbertAssist.Trace

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

  defmodule FakeSmtpClient do
    def send(from, to, subject, body, opts) do
      Kernel.send(Keyword.fetch!(opts, :test_pid), {:smtp_sent, from, to, subject, body, opts})
      :ok
    end
  end

  setup do
    original_env = Map.new(["ALLBERT_HOME", "ALLBERT_HOME_DIR"], &{&1, System.get_env(&1)})
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)

    Enum.each(Map.keys(original_env), &System.delete_env/1)
    Application.delete_env(:allbert_assist, Confirmations)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Runtime)
    Application.delete_env(:allbert_assist, Settings)
    Application.delete_env(:allbert_assist, Trace)

    home =
      Path.join(System.tmp_dir!(), "allbert-email-test-#{System.unique_integer([:positive])}")

    System.put_env("ALLBERT_HOME", home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    PluginRegistry.clear()
    assert {:ok, "allbert.email"} = PluginRegistry.register_module(AllbertAssist.Plugins.Email)

    on_exit(fn ->
      File.rm_rf!(home)
      ShippedRegistries.restore!()
      restore_env(original_env)
      restore_app_env(Confirmations, original_confirmations_config)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Runtime, original_runtime_config)
      restore_app_env(Settings, original_settings_config)
      restore_app_env(Trace, original_trace_config)
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

    test "decodes encoded headers and content-transfer-encoded text bodies" do
      assert {:ok, fields} = Parser.parse_email(encoded_email())

      assert fields.from_address == "alice@example.com"
      assert fields.subject == "Prüfung"
      assert fields.text_body == "Prüfung ✓\n"

      assert {:ok, multipart} = Parser.parse_email(multipart_encoded_email())
      assert multipart.text_body == "Plain hello\n"
      assert multipart.html_body == "<p>HTML hello</p>\n"
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

    test "formats RFC-style date, transfer encoding, and encoded-word headers" do
      message =
        SmtpClient.format_message(
          "allbert@example.com",
          "alice@example.com",
          "Café",
          "body",
          from_name: "Allbért",
          date: ~U[2026-06-14 12:00:00Z]
        )

      assert message =~ "Date: Sun, 14 Jun 2026 12:00:00 +0000"
      assert message =~ "MIME-Version: 1.0"
      assert message =~ "Content-Transfer-Encoding: 8bit"
      assert message =~ "Subject: =?UTF-8?B?"
      assert message =~ "From: =?UTF-8?B?"
    end
  end

  describe "renderer" do
    test "renders normal replies and approval handoff commands" do
      assert {:ok, "Re: Hi", body, nil} =
               Renderer.render_response(%{message: "abcdef"}, subject: "Hi", max_body_bytes: 3)

      assert body =~ "abc"
      assert body =~ "Truncated locally"

      handoff = %{
        confirmation_id: "conf_123",
        status: :pending,
        target_action: %{action: %{name: "run_skill_script"}}
      }

      assert {:ok, "Re: Approval", handoff_body, nil} =
               Renderer.render_response(%{approval_handoff: handoff}, subject: "Approval")

      assert handoff_body =~ "ALLBERT:APPROVE:conf_123"
      assert handoff_body =~ "ALLBERT:DENY:conf_123"
    end

    test "renders objective snapshot and stale warning for approval handoffs" do
      assert {:ok, objective} =
               Objectives.create_objective(%{
                 user_id: "alice",
                 title: "Analyze AAPL",
                 objective: "Complete one analysis for AAPL.",
                 status: "running"
               })

      handoff = %{
        confirmation_id: "conf_obj",
        status: :pending,
        objective_id: objective.id,
        target_action: %{
          action: %{name: "run_analysis"},
          params_summary: %{
            objective_id: objective.id,
            objective_title: "Analyze AAPL",
            objective_status: "running"
          }
        }
      }

      assert {:ok, _cancelled} =
               Objectives.update_objective(objective, %{
                 status: "cancelled",
                 progress_summary: "Cancelled in renderer test."
               })

      assert {:ok, _subject, body, nil} =
               Renderer.render_response(%{approval_handoff: handoff}, subject: "Approval")

      assert body =~ "Objective: #{objective.id}"
      assert body =~ "Title: Analyze AAPL"
      assert body =~ "Status: :cancelled"
      assert body =~ "Note: objective is now :cancelled"
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
      configure_runtime!()

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

      event = Channels.get_event_by_external_id("email", "msg-1@example.com")
      assert event.status == "processed"
      assert event.user_id == "alice"
      assert String.starts_with?(event.session_id, "ch_em_")
      assert String.starts_with?(event.thread_id, "thr_")
      assert is_binary(event.input_signal_id)
      assert is_binary(event.trace_id)

      assert {:ok, %{messages: messages}} = Conversations.show_thread("alice", event.thread_id)
      assert Enum.any?(messages, &(&1.content == "Hi Allbert"))

      assert_received {:smtp_sent, "allbert@example.com", "alice@example.com", "Re: Hello", body,
                       opts}

      assert body =~ "Runtime response: Hi Allbert"
      assert opts[:in_reply_to] == "msg-1@example.com"
      assert is_binary(opts[:message_id])
      assert opts[:message_id] =~ "@allbert.local"

      assert_received {:runtime_request,
                       %{
                         channel: "email",
                         user_id: "alice",
                         provider_message_id: "msg-1@example.com"
                       } = request}

      assert request.channel_thread_ref.channel == "email"

      assert request.channel_thread_ref.receiver_account_ref ==
               "email:mailbox:allbert@example.com"

      assert request.channel_thread_ref.provider_thread_ref["provider_thread_root"] ==
               "msg-1@example.com"

      refs =
        ConversationMessageRef
        |> where([ref], ref.channel == "email")
        |> order_by([ref], asc: ref.direction)
        |> Repo.all()

      assert Enum.any?(
               refs,
               &(&1.direction == "in" and &1.provider_message_id == "msg-1@example.com")
             )

      assert Enum.any?(
               refs,
               &(&1.direction == "out" and &1.provider_message_id == opts[:message_id])
             )
    end

    test "dedupes replayed Message-ID values and still marks seen" do
      configure_email!()
      configure_runtime!()
      fake = start_fake_imap!(%{"1" => plain_email()})
      server = :"email-duplicate-#{System.unique_integer([:positive])}"
      start_email_server!(server, fake)

      assert {:ok, %{processed: 1}} = Adapter.poll_once(server)
      assert {:ok, %{duplicates: 1}} = Adapter.poll_once(server)
      assert Agent.get(fake, &length(&1.seen)) == 2
    end

    test "resumes replayed Message-ID values left in received state" do
      configure_email!()
      configure_runtime!()
      fake = start_fake_imap!(%{"1" => plain_email("msg-resume@example.com")})

      assert {:ok, _event} =
               Channels.create_event(%{
                 channel: "email",
                 provider: "email_imap",
                 direction: "inbound",
                 external_event_id: "msg-resume@example.com",
                 external_user_id: "alice@example.com",
                 external_message_id: "1",
                 status: "received"
               })

      server = :"email-resume-received-#{System.unique_integer([:positive])}"
      start_email_server!(server, fake)

      assert {:ok, %{processed: 1, duplicates: 0, rejected: 0, failed: 0}} =
               Adapter.poll_once(server)

      assert_received {:runtime_request, %{text: "Hi Allbert"}}

      event = Channels.get_event_by_external_id("email", "msg-resume@example.com")
      assert event.status == "processed"
      assert event.user_id == "alice"
      assert String.starts_with?(event.thread_id, "thr_")
    end

    test "suppresses email echoes by outbound Message-ID" do
      configure_email!()
      configure_runtime!()
      fake = start_fake_imap!(%{"1" => plain_email()})
      server = :"email-echo-#{System.unique_integer([:positive])}"
      start_email_server!(server, fake)

      assert {:ok, %{processed: 1}} = Adapter.poll_once(server)
      assert_received {:runtime_request, %{text: "Hi Allbert"}}

      assert_received {:smtp_sent, _from, _to, _subject, _body, opts}
      outbound_message_id = Keyword.fetch!(opts, :message_id)

      Agent.update(fake, fn state ->
        put_in(state.messages["2"], plain_email(outbound_message_id))
      end)

      assert {:ok, %{duplicates: 1, rejected: 1}} = Adapter.poll_once(server)
      refute_received {:runtime_request, %{provider_message_id: ^outbound_message_id}}

      event = Channels.get_event_by_external_id("email", outbound_message_id)
      assert event.status == "rejected"
      assert event.reason == ":echo_suppressed"
    end

    test "unmapped senders and oversized bodies are rejected before runtime" do
      configure_email!(identity_map: [])
      configure_runtime!()
      fake = start_fake_imap!(%{"1" => plain_email()})
      server = :"email-unmapped-#{System.unique_integer([:positive])}"
      start_email_server!(server, fake)

      assert {:ok, %{rejected: 1}} = Adapter.poll_once(server)
      assert Channels.get_event_by_external_id("email", "msg-1@example.com").status == "rejected"
      refute_received {:runtime_request, _request}
      stop_supervised(Adapter)

      configure_email!(identity_map: [%{external_user_id: "alice@example.com", user_id: "alice"}])

      assert {:ok, _setting} =
               Settings.put("channels.email.max_body_bytes", 4, %{audit?: false})

      fake = start_fake_imap!(%{"2" => plain_email("msg-oversized@example.com")})
      server = :"email-oversized-#{System.unique_integer([:positive])}"
      start_email_server!(server, fake)

      assert {:ok, %{rejected: 1}} = Adapter.poll_once(server)
      event = Channels.get_event_by_external_id("email", "msg-oversized@example.com")
      assert event.reason == ":oversized"
    end

    test "html-only confirmation text is rejected as inbound when html replies are disabled" do
      configure_email!()
      configure_runtime!()

      fake =
        start_fake_imap!(%{
          "1" =>
            html_only_email(
              "html-command@example.com",
              "<p>ALLBERT:DENY:conf_email_html</p>"
            )
        })

      server = :"email-html-only-command-#{System.unique_integer([:positive])}"
      start_email_server!(server, fake)

      assert {:ok, %{processed: 0, rejected: 1}} = Adapter.poll_once(server)

      event = Channels.get_event_by_external_id("email", "html-command@example.com")
      assert event.direction == "inbound"
      assert event.status == "rejected"
      assert event.reason == ":html_only"
      refute_received {:runtime_request, _request}
    end

    test "typed confirmation commands resolve through registered actions" do
      configure_email!()
      assert {:ok, confirmation} = create_confirmation!("conf_email_deny", "email")

      fake =
        start_fake_imap!(%{
          "1" => command_email("cmd-1@example.com", "ALLBERT:DENY:#{confirmation["id"]}")
        })

      server = :"email-command-#{System.unique_integer([:positive])}"
      start_email_server!(server, fake)

      assert {:ok, %{processed: 1, rejected: 0}} = Adapter.poll_once(server)

      assert {:ok, resolved} = Confirmations.read(confirmation["id"])
      assert resolved["status"] == "denied"
      assert resolved["operator_resolution"]["resolver_actor"] == "alice"
      assert resolved["operator_resolution"]["resolver_channel"] == "email"
      assert resolved["operator_resolution"]["resolver_metadata"]["external_message_id"] == "1"

      event = Channels.get_event_by_external_id("email", "cmd-1@example.com")
      assert event.direction == "callback"
      assert event.status == "processed"
      assert event.user_id == "alice"
      assert String.starts_with?(event.session_id, "ch_em_")
      assert is_binary(event.input_signal_id)

      assert_received {:smtp_sent, "allbert@example.com", "alice@example.com", "Re: Confirm",
                       body, opts}

      assert body =~ "denied"
      assert opts[:in_reply_to] == "cmd-1@example.com"
    end

    test "typed approve command uses the same confirmation action boundary" do
      configure_email!()
      assert {:ok, confirmation} = create_confirmation!("conf_email_approve", "email")

      fake =
        start_fake_imap!(%{
          "1" => command_email("cmd-approve@example.com", "ALLBERT:APPROVE:#{confirmation["id"]}")
        })

      server = :"email-approve-command-#{System.unique_integer([:positive])}"
      start_email_server!(server, fake)

      assert {:ok, %{processed: 1}} = Adapter.poll_once(server)
      assert {:ok, resolved} = Confirmations.read(confirmation["id"])
      assert resolved["status"] == "adapter_unavailable"

      assert_received {:smtp_sent, "allbert@example.com", "alice@example.com", "Re: Confirm",
                       body, _opts}

      assert body =~ "Approved, but not executed"
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

  defp configure_email!(opts \\ []) do
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

    identity_map =
      Keyword.get(opts, :identity_map, [
        %{external_user_id: "alice@example.com", user_id: "alice"}
      ])

    assert {:ok, _setting} =
             Settings.put("channels.email.identity_map", identity_map, %{audit?: false})
  end

  defp configure_runtime! do
    parent = self()

    AllbertAssist.TraceTestSupport.enable_trace_default!()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        Kernel.send(parent, {:runtime_request, request})
        {:ok, %{message: "Runtime response: #{request.text}", status: :completed}}
      end
    )
  end

  defp start_fake_imap!(messages) do
    name = :"fake-imap-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Agent.start(fn -> %{messages: messages, seen: []} end, name: name)
    on_exit(fn -> if Process.whereis(name), do: Agent.stop(name) end)
    name
  end

  defp start_email_server!(server, fake_name) do
    start_supervised!(
      {Adapter,
       name: server,
       auto_poll?: false,
       imap_client: FakeImapClient,
       smtp_client: FakeSmtpClient,
       client_opts: [fake_name: fake_name, test_pid: self()]}
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

  defp encoded_email do
    """
    From: =?UTF-8?Q?Alice_=C3=84?= <Alice@Example.COM>
    To: allbert@example.com
    Subject: =?UTF-8?Q?Pr=C3=BCfung?=
    Message-ID: <encoded-1@example.com>
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    Pr=C3=BCfung =E2=9C=93
    """
  end

  defp multipart_encoded_email do
    """
    From: Alice <alice@example.com>
    To: allbert@example.com
    Subject: Encoded Multipart
    Message-ID: <encoded-2@example.com>
    Content-Type: multipart/alternative; boundary="enc"

    --enc
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: base64

    UGxhaW4gaGVsbG8K
    --enc
    Content-Type: text/html; charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    <p>HTML hello</p>
    --enc--
    """
  end

  defp command_email(message_id, command) do
    """
    From: Alice <alice@example.com>
    To: allbert@example.com
    Subject: Confirm
    Message-ID: <#{message_id}>
    Content-Type: text/plain; charset=utf-8

    #{command}
    """
  end

  defp html_only_email(message_id, html_body) do
    """
    From: Alice <alice@example.com>
    To: allbert@example.com
    Subject: Confirm
    Message-ID: <#{message_id}>
    Content-Type: text/html; charset=utf-8

    #{html_body}
    """
  end

  defp create_confirmation!(id, channel) do
    Confirmations.create(%{
      id: id,
      origin: %{actor: "alice", channel: channel, surface: "channel-test"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{url: "https://example.com"}
    })
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
