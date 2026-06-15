defmodule AllbertAssist.Channels.WhatsAppTest do
  use AllbertAssist.DataCase, async: false

  import Ecto.Query
  import Plug.Conn

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Channels.WhatsApp.Adapter
  alias AllbertAssist.Channels.WhatsApp.Client
  alias AllbertAssist.Channels.WhatsApp.Parser
  alias AllbertAssist.Conversations.ConversationMessageRef
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Plugins.WhatsApp, as: WhatsAppPlugin
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Trace

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)
    original_plugins = PluginRegistry.registered_plugins()

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-whatsapp-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    PluginRegistry.clear()
    assert {:ok, "allbert.whatsapp"} = PluginRegistry.register_module(WhatsAppPlugin)
    Fragments.clear_cache()

    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        Kernel.send(parent, {:runtime_request, request})

        {:ok,
         %{
           message: "WhatsApp response: #{request.text}",
           status: :completed,
           assistant_message_id: Ecto.UUID.generate(),
           thread_id: request[:thread_id] || Ecto.UUID.generate()
         }}
      end
    )

    configure_whatsapp!()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      restore_plugins(original_plugins)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "plugin descriptor declares WhatsApp channel contract with mandatory list primitive" do
    assert [descriptor] = WhatsAppPlugin.channels()

    assert descriptor.channel_id == "whatsapp"
    assert descriptor.provider == "whatsapp_cloud_api"
    assert descriptor.primitives == [:button, :typed_command, :link, :list]
    assert descriptor.threading == :reply_chain
    assert descriptor.trust_class == :server_readable
    assert descriptor.reply_key_type == :opaque_id
    assert descriptor.quote_ttl_ms == 86_400_000
    assert descriptor.settings_prefix == "channels.whatsapp"

    assert {:ok, descriptor} = Channels.channel_descriptor("whatsapp")
    assert :list in descriptor.primitives
  end

  test "settings fragment reports required fields when WhatsApp is enabled" do
    diagnostics =
      AllbertWhatsApp.Settings.Fragment.required_when_enabled(%{
        "enabled" => true,
        "access_token_ref" => "",
        "phone_number_id" => ""
      })

    assert :missing_access_token_ref in diagnostics
    assert :missing_phone_number_id in diagnostics
  end

  test "client uses bearer auth and Graph API message paths without query credentials" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v23.0/15551234567/messages"
      assert get_req_header(conn, "authorization") == ["Bearer whatsapp-secret"]
      refute conn.query_string =~ "access_token"

      {:ok, body, conn} = read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["messaging_product"] == "whatsapp"
      assert decoded["type"] == "text"
      assert decoded["context"] == %{"message_id" => "wamid.parent"}

      json(conn, %{"messages" => [%{"id" => "wamid.outbound"}]})
    end)

    assert {:ok, %{"messages" => [%{"id" => "wamid.outbound"}]}} =
             Client.send_text(
               "whatsapp-secret",
               "15551234567",
               "+15550001111",
               "hello",
               context_message_id: "wamid.parent",
               plug: {Req.Test, __MODULE__}
             )

    request =
      Client.send_text_request("15551234567", "+15550001111", "hello",
        context_message_id: "wamid.parent"
      )

    assert request.method == :post
    assert request.path == "/v23.0/15551234567/messages"
    assert request.body["context"] == %{"message_id" => "wamid.parent"}
    assert inspect(request) =~ "[REDACTED]"
    refute inspect(request) =~ "whatsapp-secret"
  end

  test "parser extracts text and button webhook events" do
    text_payload =
      Parser.simulated_text_webhook(%{
        from: "+15550001111",
        phone_number_id: "15551234567",
        message_id: "wamid.inbound",
        text: "hello whatsapp",
        context_message_id: "wamid.parent"
      })

    button_payload =
      Parser.simulated_button_webhook(%{
        from: "+15550001111",
        phone_number_id: "15551234567",
        message_id: "wamid.button",
        button_id: "allbert:v1:approve:confirm_123"
      })

    assert [{:text_message, text_fields}] = Parser.parse_webhook(text_payload)
    assert text_fields.external_user_id == "+15550001111"
    assert text_fields.phone_number_id == "15551234567"
    assert text_fields.text == "hello whatsapp"
    assert text_fields.context_message_id == "wamid.parent"

    assert [{:button_reply, button_fields}] = Parser.parse_webhook(button_payload)
    assert button_fields.verb == :approve
    assert button_fields.confirmation_id == "confirm_123"
    assert button_fields.button_id == "allbert:v1:approve:confirm_123"
  end

  test "adapter processes simulated webhook, sends quoted reply, records refs, and redacts phones" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v23.0/15551234567/messages"

      {:ok, body, conn} = read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["to"] == "+15550001111"
      assert decoded["text"]["body"] == "WhatsApp response: hello whatsapp"
      assert decoded["context"] == %{"message_id" => "wamid.inbound"}

      json(conn, %{"messages" => [%{"id" => "wamid.outbound"}]})
    end)

    payload =
      Parser.simulated_text_webhook(%{
        from: "+15550001111",
        phone_number_id: "15551234567",
        display_phone_number: "+15551234567",
        message_id: "wamid.inbound",
        text: "hello whatsapp"
      })

    server = :"whatsapp-adapter-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Adapter.start_link(
               name: server,
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    Req.Test.allow(__MODULE__, self(), pid)

    assert {:ok, %{processed: 1, duplicates: 0, rejected: 0, failed: 0}} =
             Adapter.simulate_webhook_event(server, payload)

    assert_receive {:runtime_request, request}, 1000
    assert request.channel == "whatsapp"
    assert request.user_id == "alice"
    assert request.metadata.provider_thread_ref.provider == "whatsapp"
    assert request.metadata.receiver_account_ref =~ "[REDACTED_PHONE]"
    refute inspect(request.metadata) =~ "+15551234567"

    assert %ConversationMessageRef{} =
             Repo.one(
               from ref in ConversationMessageRef,
                 where: ref.channel == "whatsapp" and ref.provider_message_id == "wamid.outbound"
             )

    assert %Event{external_user_id: "[REDACTED_PHONE]"} =
             Repo.one(from event in Event, where: event.channel == "whatsapp")

    GenServer.stop(pid)
  end

  test "adapter degrades reply-chain quotes after quote TTL expires" do
    old_timestamp = DateTime.utc_now() |> DateTime.add(-2, :day) |> DateTime.to_unix()

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = read_body(conn)
      decoded = Jason.decode!(body)
      refute Map.has_key?(decoded, "context")
      json(conn, %{"messages" => [%{"id" => "wamid.outbound.old"}]})
    end)

    payload =
      Parser.simulated_text_webhook(%{
        from: "+15550001111",
        phone_number_id: "15551234567",
        message_id: "wamid.old",
        timestamp: old_timestamp,
        text: "old quote"
      })

    server = :"whatsapp-adapter-old-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             Adapter.start_link(
               name: server,
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    Req.Test.allow(__MODULE__, self(), pid)

    assert {:ok, %{processed: 1}} = Adapter.simulate_webhook_event(server, payload)

    GenServer.stop(pid)
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
             Settings.put("channels.whatsapp.waba_id", "waba-1", %{audit?: false})

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
end
