defmodule AllbertAssist.Security.V053ChannelPackEvalTest do
  use AllbertAssist.DataCase, async: false, lane: :security_eval_serial

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Email.Parser, as: EmailParser
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Channels.InboundTrust
  alias AllbertAssist.Channels.Matrix.Parser, as: MatrixParser
  alias AllbertAssist.Channels.Signal.Daemon, as: SignalDaemon
  alias AllbertAssist.Channels.Signal.Parser, as: SignalParser
  alias AllbertAssist.Channels.Telegram.Renderer, as: TelegramRenderer
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.UnifiedHistory
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugin.Validator
  alias AllbertAssist.PublicProtocol.HttpIngress
  alias AllbertAssist.PublicProtocol.RateLimiter
  alias AllbertAssist.Runtime
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.TestSupport.ShippedRegistries
  alias AllbertAssist.Trace

  defmodule InvalidDescriptorPlugin do
    use AllbertAssist.Plugin

    @impl true
    def plugin_id, do: "v053.invalid_descriptor"

    @impl true
    def display_name, do: "v0.53 Invalid Descriptor"

    @impl true
    def version, do: "0.53.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def channels do
      [
        %{
          channel_id: "invalid_descriptor",
          provider: "invalid",
          primitives: [:button],
          threading: :reply_chain,
          trust_class: :internet,
          reply_key_type: :phone_number,
          quote_ttl_ms: 0
        }
      ]
    end
  end

  @eval_groups [
    key_custody_and_webhook: [
      "key-custody-no-leak-001",
      "key-custody-fetch-audited-001",
      "whatsapp-webhook-signature-verify-before-parse-001",
      "whatsapp-webhook-bad-signature-deny-001"
    ],
    signal: [
      "signal-cli-control-endpoint-local-001",
      "signal-cli-unix-socket-0600-001",
      "signal-cli-keyfiles-0600-001",
      "phone-number-redaction-001",
      "signal-aci-identity-not-phone-001"
    ],
    descriptors_and_policy: [
      "trust-class-stamped-per-channel-001",
      "descriptor-flag-validation-001",
      "matrix-unencrypted-rooms-only-001",
      "channel-metadata-not-authority-001"
    ],
    threading_and_history: [
      "e2ee-origin-excluded-default-unified-view-001",
      "e2ee-origin-optin-audited-001",
      "resume-downgrade-confirmed-audited-001",
      "reply-by-timestamp-001",
      "quote-ttl-degrade-to-flat-001",
      "provider-thread-not-authority-001",
      "identity-link-no-auto-merge-001"
    ],
    channel_pack_1_regressions: [
      "email-content-transfer-encoding-decoded-001",
      "telegram-callback-data-within-64b-001"
    ]
  ]
  @eval_ids @eval_groups |> Keyword.values() |> List.flatten()

  @signal_aci "2f8f8f44-8f1a-4db3-a56a-8e0612f6f001"
  @phone_number_id "15551234567"

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)

    parent = self()

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-v053-channel-pack-eval-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.delete_env(:allbert_assist, Trace)

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:runtime_request, request})

        {:ok,
         %{
           message: "v0.53 eval response: #{request.text}",
           status: :completed,
           actions: []
         }}
      end
    )

    PluginRegistry.clear()

    assert {:ok, "allbert.telegram"} =
             PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)

    assert {:ok, "allbert.email"} = PluginRegistry.register_module(AllbertAssist.Plugins.Email)
    assert {:ok, "allbert.matrix"} = PluginRegistry.register_module(AllbertAssist.Plugins.Matrix)

    assert {:ok, "allbert.whatsapp"} =
             PluginRegistry.register_module(AllbertAssist.Plugins.WhatsApp)

    assert {:ok, "allbert.signal"} = PluginRegistry.register_module(AllbertAssist.Plugins.Signal)
    Fragments.clear_cache()
    RateLimiter.reset_for_test()

    configure_channels!()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      ShippedRegistries.restore!()
      Fragments.clear_cache()
      RateLimiter.reset_for_test()
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "v0.53 eval inventory rows are complete" do
    rows = EvalInventory.rows_for_milestone(:v053)
    row_ids = Enum.map(rows, & &1.id)

    assert MapSet.new(row_ids) == MapSet.new(@eval_ids)
    assert length(row_ids) == length(@eval_ids)
    assert Enum.all?(rows, &(&1.surface == :channel_pack))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
  end

  test "key custody stores encrypted values and WhatsApp webhooks verify before parse", %{
    root: root
  } do
    assert_eval_group!(:key_custody_and_webhook)

    app_secret = "whatsapp-v053-app-secret"
    verify_token = "whatsapp-v053-verify-token"
    raw_body = "{not-json"

    put_secret!("secret://channels/whatsapp/app_secret", app_secret)
    put_secret!("secret://channels/whatsapp/webhook_verify_token", verify_token)

    assert {:ok, ^app_secret} =
             Secrets.get_secret("secret://channels/whatsapp/app_secret", %{
               actor: "v053-eval",
               channel: :test
             })

    assert File.exists?(Secrets.secrets_path())
    refute File.read!(Secrets.secrets_path()) =~ app_secret
    refute File.read!(Secrets.key_path()) =~ app_secret

    audit_text =
      root
      |> Path.join("settings/audit/*.md")
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    assert audit_text =~ "secret://channels/whatsapp/app_secret"
    assert audit_text =~ "v053-eval"
    refute audit_text =~ app_secret

    signature = whatsapp_signature(app_secret, raw_body)

    assert {:ok, auth} =
             HttpIngress.authenticate_webhook(
               "whatsapp_webhook",
               [{"x-hub-signature-256", signature}],
               raw_body,
               "/webhooks/whatsapp/#{@phone_number_id}"
             )

    assert auth.surface == "whatsapp_webhook"
    assert auth.client_id == @phone_number_id
    assert auth.token_ref == "secret://channels/whatsapp/app_secret"

    assert {:error, :invalid_webhook_signature} =
             HttpIngress.authenticate_webhook(
               "whatsapp_webhook",
               [{"x-hub-signature-256", whatsapp_signature("wrong-secret", raw_body)}],
               raw_body,
               "/webhooks/whatsapp/#{@phone_number_id}"
             )
  end

  test "Signal custody is local, socket/key modes are restricted, and identity uses ACI", %{
    root: root
  } do
    assert_eval_group!(:signal)

    data_dir = Path.join(root, "signal")
    File.mkdir_p!(data_dir)
    key_file = Path.join(data_dir, "account.db")
    socket_file = Path.join(data_dir, "signal-cli.sock")
    File.write!(key_file, "fixture")
    File.write!(socket_file, "")
    File.chmod!(key_file, 0o644)
    File.chmod!(socket_file, 0o600)

    custody = SignalDaemon.ensure_custody!(%{"data_dir" => data_dir})

    control =
      SignalDaemon.control_diagnostics(%{
        "control_mode" => "socket",
        "socket_path" => socket_file
      })

    assert custody.data_dir == data_dir
    assert custody.directory_mode == 0o700
    assert custody.key_files["account.db"] == 0o600
    assert control.ok?
    assert control.local_only?
    assert control.socket_mode == 0o600

    loopback =
      SignalDaemon.control_diagnostics(%{
        "control_mode" => "loopback_http",
        "loopback_http_base_url" => "http://127.0.0.1:8080",
        "control_auth_ref" => "secret://channels/signal/control_auth"
      })

    assert loopback.ok?
    assert loopback.local_only?
    assert loopback.auth_configured?

    non_loopback =
      SignalDaemon.control_diagnostics(%{
        "control_mode" => "loopback_http",
        "loopback_http_base_url" => "https://signal.example.com",
        "control_auth_ref" => "secret://channels/signal/control_auth"
      })

    refute non_loopback.ok?
    assert :not_loopback in non_loopback.diagnostics

    notification =
      SignalParser.simulated_receive_notification(%{
        source_aci: "aci:" <> @signal_aci,
        source_number: "+15550001111",
        timestamp_ms: 1_781_477_600_000,
        text: "hello signal"
      })

    assert [{:text_message, fields}] = SignalParser.parse_notification(notification)
    assert fields.external_user_id == @signal_aci
    assert fields.source_aci == @signal_aci
    refute fields.external_user_id == fields.source_number

    refute inspect(Map.take(fields, [:external_user_id, :external_chat_id, :send_recipient])) =~
             "+15550001111"

    assert {:error, {:invalid_signal_identity, :aci_required}} =
             ChannelThread.link_identity(%{
               link_id: "signal-phone-v053",
               user_id: "alice",
               channel: "signal",
               receiver_account_ref: "signal:+15551234567",
               external_user_id: "+15550001111"
             })

    assert Identity.resolve("signal", "+15550001111", signal_identity_map()) ==
             {:error, :not_mapped}
  end

  test "descriptors require list primitive, policy floor ignores channel metadata, and Matrix rejects encrypted rooms" do
    assert_eval_group!(:descriptors_and_policy)

    for channel <- ~w[telegram email matrix whatsapp signal],
        {:ok, descriptor} = Channels.channel_descriptor(channel) do
      assert :list in descriptor.primitives
      assert descriptor.trust_class in [:server_readable, :e2ee_origin]
      assert Map.get(descriptor, :reply_key_type) in [nil, :opaque_id, :timestamp]
    end

    assert {:error, :invalid_plugin, diagnostics} =
             Validator.validate_module(InvalidDescriptorPlugin)

    diagnostic_kinds = Enum.map(diagnostics, & &1.kind)
    assert :missing_channel_list_primitive in diagnostic_kinds
    assert :invalid_channel_trust_class in diagnostic_kinds
    assert :invalid_channel_reply_key_type in diagnostic_kinds
    assert :invalid_channel_quote_ttl_ms in diagnostic_kinds

    assert [{:unsupported, encrypted}] =
             MatrixParser.parse_sync(%{
               "rooms" => %{
                 "join" => %{
                   "!room:example.org" => %{
                     "timeline" => %{
                       "events" => [
                         %{
                           "event_id" => "$encrypted",
                           "type" => "m.room.encrypted",
                           "content" => %{"algorithm" => "m.megolm.v1.aes-sha2"}
                         }
                       ]
                     }
                   }
                 }
               }
             })

    assert encrypted.type == "encrypted_not_supported"

    assert {:ok, auth} =
             InboundTrust.authorize(%{
               channel: "signal",
               provider: "signal_cli_jsonrpc",
               external_user_id: @signal_aci,
               external_chat_id: @signal_aci,
               metadata_claims_allowed?: true
             })

    assert auth.permission == :channel_message_inbound
    assert auth.decision == :needs_confirmation
    assert auth.safety_floor == :needs_confirmation

    assert {:ok, _response} =
             Runtime.submit_user_input(%{
               text: "signal trust stamp",
               channel: "signal",
               user_id: "alice",
               receiver_account_ref: "signal:+15551234567",
               provider_thread_ref: %{
                 "message_timestamp_ms" => 1_781_477_600_000,
                 "author_aci" => @signal_aci
               },
               metadata: %{claimed_trust_class: :server_readable}
             })

    assert_receive {:runtime_request, request}
    assert request.channel_thread_ref.trust_class == "e2ee_origin"
  end

  test "threading and unified history preserve authority, E2EE opt-in, and downgrade confirmation",
       %{root: root} do
    assert_eval_group!(:threading_and_history)

    assert {:ok, thread} = Conversations.create_general_thread("alice", "v0.53 E2EE thread")
    assert {:ok, signal_message} = Conversations.append_user_message(thread, "signal secret")
    assert {:ok, public_message} = Conversations.append_assistant_message(thread, "public ok")

    assert {:ok, _signal_ref} =
             ChannelThread.record_message_ref(%{
               channel: "signal",
               receiver_account_ref: "signal:+15551234567",
               provider_message_id: "1781477600000",
               canonical_thread_id: thread.id,
               canonical_message_id: signal_message.id,
               direction: :in,
               trust_class: :e2ee_origin
             })

    assert {:ok, _email_ref} =
             ChannelThread.record_message_ref(%{
               channel: "email",
               receiver_account_ref: "email:inbox",
               provider_message_id: "<public@example.com>",
               canonical_thread_id: thread.id,
               canonical_message_id: public_message.id,
               direction: :out,
               trust_class: :server_readable
             })

    assert {:ok, hidden} = UnifiedHistory.show_thread("alice", thread.id, viewer_channel: "email")
    assert Enum.map(hidden.messages, & &1.content) == ["public ok"]
    assert hidden.trust.filtered_e2ee_origin_count == 1

    assert {:ok, visible} =
             UnifiedHistory.show_thread("alice", thread.id,
               viewer_channel: "email",
               include_e2ee_origin: true,
               audit_context: %{actor: "operator-v053"}
             )

    assert Enum.map(visible.messages, & &1.content) == ["signal secret", "public ok"]
    assert visible.trust.audit.audit_path
    assert File.read!(visible.trust.audit.audit_path) =~ "operator-v053"

    assert {:ok, _identity} =
             ChannelThread.link_identity(%{
               link_id: "alice-email-v053",
               user_id: "alice",
               channel: "email",
               receiver_account_ref: "email:inbox",
               external_user_id: "alice@example.com"
             })

    assert {:error, {:trust_downgrade_requires_confirmation, downgrade}} =
             UnifiedHistory.resume_thread_on_channel(%{
               thread_id: thread.id,
               user_id: "alice",
               channel: "email",
               receiver_account_ref: "email:inbox",
               external_user_id: "alice@example.com",
               provider_thread_ref: %{"message_id" => "<public@example.com>"}
             })

    assert downgrade.source_trust_class == :e2ee_origin
    assert downgrade.target_trust_class == :server_readable

    assert {:ok, resume} =
             UnifiedHistory.resume_thread_on_channel(%{
               thread_id: thread.id,
               user_id: "alice",
               channel: "email",
               receiver_account_ref: "email:inbox",
               external_user_id: "alice@example.com",
               provider_thread_ref: %{"message_id" => "<public@example.com>"},
               confirmed_trust_downgrade?: true,
               operator_id: "operator-v053"
             })

    assert resume.trust_class == :server_readable

    audit_text =
      root
      |> Path.join("settings/audit/*.md")
      |> Path.wildcard()
      |> Enum.map_join("\n", &File.read!/1)

    assert audit_text =~ "conversations.resume_thread_on_channel.trust_downgrade"
    assert audit_text =~ "operator-v053"

    signal_ref = %{
      channel: "signal",
      receiver_account_ref: "signal:+15551234567",
      provider_thread_ref: %{
        "message_timestamp_ms" => 1_781_477_600_000,
        "author_aci" => @signal_aci
      },
      trust_class: :e2ee_origin
    }

    assert {:ok, reply_target} =
             ChannelThread.resolve_reply_target(signal_ref, %{
               threading: :reply_chain,
               reply_key_type: :timestamp,
               trust_class: :e2ee_origin
             })

    assert reply_target.reply_key == %{
             type: :timestamp,
             timestamp_ms: 1_781_477_600_000,
             author_ref: @signal_aci
           }

    checked_at = DateTime.from_unix!(1_781_477_700_000, :millisecond)

    assert {:ok, degraded} =
             ChannelThread.resolve_reply_target(
               %{
                 channel: "whatsapp",
                 receiver_account_ref: "whatsapp:#{@phone_number_id}",
                 provider_thread_ref: %{
                   "message_id" => "wamid.old",
                   "message_timestamp_ms" => 1_781_477_600_000
                 },
                 trust_class: :server_readable,
                 now: checked_at
               },
               %{threading: :reply_chain, reply_key_type: :opaque_id, quote_ttl_ms: 1_000}
             )

    assert degraded.threading == :flat
    assert degraded.degradation == :quote_ttl_expired
    assert degraded.quote_window.expired?

    assert {:error, :not_found} =
             ChannelThread.lookup_thread(%{
               channel: "matrix",
               receiver_account_ref: "matrix:@alice:example.org",
               provider_thread_ref: %{"room_id" => "!unlinked:example.org"}
             })

    assert {:ok, _matrix_identity} =
             ChannelThread.link_identity(%{
               link_id: "alice-matrix-v053",
               user_id: "alice",
               channel: "matrix",
               receiver_account_ref: "matrix:allbert",
               external_user_id: "@alice:example.org"
             })

    assert {:ok, []} = Settings.get("channels.matrix.identity_map")
    assert {:ok, []} = Settings.get("channels.whatsapp.identity_map")
    assert {:ok, []} = Settings.get("channels.signal.identity_map")
  end

  test "email transfer encodings and encoded words decode before runtime text selection" do
    assert_eval!("email-content-transfer-encoding-decoded-001")

    assert {:ok, quoted} =
             EmailParser.parse_email("""
             From: =?UTF-8?Q?Alice_=C3=84?= <Alice@Example.COM>
             To: allbert@example.com
             Subject: =?UTF-8?Q?Pr=C3=BCfung?=
             Message-ID: <v053-encoded@example.com>
             Content-Type: text/plain; charset=utf-8
             Content-Transfer-Encoding: quoted-printable

             Pr=C3=BCfung =E2=9C=93
             """)

    assert quoted.from_address == "alice@example.com"
    assert quoted.subject == "Prüfung"
    assert quoted.text_body == "Prüfung ✓\n"

    assert {:ok, base64} =
             EmailParser.parse_email("""
             From: Alice <alice@example.com>
             To: allbert@example.com
             Subject: Base64
             Message-ID: <v053-base64@example.com>
             Content-Type: multipart/alternative; boundary="v053"

             --v053
             Content-Type: text/plain; charset=utf-8
             Content-Transfer-Encoding: base64

             SGVsbG8gQWxsYmVydAo=
             --v053--
             """)

    assert base64.text_body == "Hello Allbert\n"
  end

  test "Telegram approval callback data stays provider-bounded with fallback commands" do
    assert_eval!("telegram-callback-data-within-64b-001")

    assert {:ok, confirmation} =
             Confirmations.create(%{
               origin: %{actor: "alice", channel: "telegram", surface: "v053-eval"},
               target_action: %{name: "external_network_request"},
               target_permission: :external_network,
               target_execution_mode: :external_network_unavailable,
               security_decision: %{permission: :external_network, decision: :needs_confirmation},
               params_summary: %{url: "https://example.com"}
             })

    handoff = %{confirmation_id: confirmation["id"], status: :pending}

    assert {:ok, [_text], %{"inline_keyboard" => buttons}} =
             TelegramRenderer.render_response(%{approval_handoff: handoff})

    assert Enum.all?(List.flatten(buttons), &(byte_size(&1["callback_data"]) <= 64))

    long_id = "conf_" <> String.duplicate("provider-limit-", 6)

    assert {:ok, [fallback_text], nil} =
             TelegramRenderer.render_response(%{approval_handoff: %{confirmation_id: long_id}})

    assert fallback_text =~ "ALLBERT:APPROVE:#{long_id}"
    assert fallback_text =~ "ALLBERT:DENY:#{long_id}"
    assert fallback_text =~ "ALLBERT:SHOW:#{long_id}"
  end

  defp assert_eval_group!(group) do
    ids = Keyword.fetch!(@eval_groups, group)
    milestone_rows = EvalInventory.rows_for_milestone(:v053)
    rows = Enum.map(ids, &find_eval_row!(milestone_rows, &1))

    assert Enum.map(rows, & &1.id) == ids
    assert Enum.all?(rows, &(&1.milestone == :v053))
    assert Enum.all?(rows, &(&1.surface == :channel_pack))
  end

  defp assert_eval!(id) do
    assert find_eval_row!(EvalInventory.rows_for_milestone(:v053), id)
  end

  defp find_eval_row!(rows, id) do
    Enum.find(rows, &(&1.id == id)) || flunk("missing v0.53 eval row #{id}")
  end

  defp configure_channels! do
    put_setting!("channels.telegram.identity_map", telegram_identity_map())
    put_setting!("channels.email.identity_map", email_identity_map())
    put_setting!("channels.matrix.identity_map", [])
    put_setting!("channels.whatsapp.identity_map", [])
    put_setting!("channels.signal.identity_map", [])
    put_setting!("channels.whatsapp.webhook_enabled", true)
    put_setting!("channels.whatsapp.phone_number_id", @phone_number_id)
    put_setting!("channels.whatsapp.app_secret_ref", "secret://channels/whatsapp/app_secret")

    put_setting!(
      "channels.whatsapp.webhook_verify_token_ref",
      "secret://channels/whatsapp/webhook_verify_token"
    )

    put_setting!("channels.signal.control_auth_ref", "secret://channels/signal/control_auth")
    put_secret!("secret://channels/signal/control_auth", "signal-v053-control-auth")
  end

  defp put_setting!(key, value) do
    assert {:ok, _setting} = Settings.put(key, value, %{audit?: false})
  end

  defp put_secret!(secret_ref, value) do
    assert {:ok, _secret} = Secrets.put_secret(secret_ref, value, %{audit?: false})
  end

  defp whatsapp_signature(secret, raw_body) do
    digest =
      :crypto.mac(:hmac, :sha256, secret, raw_body)
      |> Base.encode16(case: :lower)

    "sha256=#{digest}"
  end

  defp telegram_identity_map do
    [%{"external_user_id" => "123456", "user_id" => "alice", "enabled" => true}]
  end

  defp email_identity_map do
    [%{"external_user_id" => "alice@example.com", "user_id" => "alice", "enabled" => true}]
  end

  defp signal_identity_map do
    [%{"external_user_id" => @signal_aci, "user_id" => "alice", "enabled" => true}]
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
