defmodule AllbertAssist.Channels.TelegramTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Telegram.Adapter
  alias AllbertAssist.Channels.Telegram.Client
  alias AllbertAssist.Channels.Telegram.Parser
  alias AllbertAssist.Channels.Telegram.Renderer
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations
  alias AllbertAssist.Paths
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Trace
  alias Plug.Conn.Query

  setup {Req.Test, :verify_on_exit!}

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
      Path.join(System.tmp_dir!(), "allbert-telegram-test-#{System.unique_integer([:positive])}")

    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)
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
    test "parses text messages" do
      assert {:text_message, fields} = Parser.parse_update(text_update(100))
      assert fields.external_event_id == "100"
      assert fields.external_user_id == "123"
      assert fields.external_chat_id == "456"
      assert fields.external_message_id == "10"
      assert fields.text == "hello"
    end

    test "parses callback queries" do
      assert {:callback_query, fields} = Parser.parse_update(callback_update(101))
      assert fields.external_event_id == "101"
      assert fields.external_user_id == "123"
      assert fields.external_chat_id == "456"
      assert fields.callback_query_id == "callback-1"
      assert fields.callback_data == "allbert:v1:show:conf_1"
    end

    test "classifies unsupported and malformed updates" do
      assert {:unsupported, %{type: "document"}} =
               Parser.parse_update(%{
                 "update_id" => 102,
                 "message" => %{"document" => %{}, "from" => %{"id" => 123}}
               })

      assert {:malformed, "missing update_id"} = Parser.parse_update(%{})
    end
  end

  describe "client" do
    test "gets updates through Telegram Bot API" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/bottoken/getUpdates"
        query = Query.decode(conn.query_string)
        assert query["offset"] == "42"
        assert query["timeout"] == "25"

        json(conn, %{"ok" => true, "result" => [text_update(42)]})
      end)

      assert {:ok, [update]} = Client.get_updates("token", 42, 25, plug: {Req.Test, __MODULE__})
      assert update["update_id"] == 42
    end

    test "sends messages and callback acknowledgements" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/bottoken/sendMessage"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["chat_id"] == "456"
        assert decoded["text"] == "hello"
        json(conn, %{"ok" => true, "result" => %{"message_id" => 99}})
      end)

      assert {:ok, %{"message_id" => 99}} =
               Client.send_message("token", "456", "hello", plug: {Req.Test, __MODULE__})

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/bottoken/answerCallbackQuery"
        json(conn, %{"ok" => true, "result" => true})
      end)

      assert {:ok, true} =
               Client.answer_callback_query("token", "callback-1", "ok",
                 plug: {Req.Test, __MODULE__}
               )
    end
  end

  describe "renderer" do
    test "chunks normal responses and renders approval handoff buttons" do
      assert {:ok, ["abc", "def"], nil} =
               Renderer.render_response(%{message: "abcdef"}, max_text_bytes: 3)

      handoff = %{
        confirmation_id: "conf_123",
        status: :pending,
        target_action: %{action: %{name: "run_skill_script"}}
      }

      assert {:ok, [text], %{"inline_keyboard" => buttons}} =
               Renderer.render_response(%{approval_handoff: handoff})

      assert text =~ "conf_123"

      assert List.flatten(buttons)
             |> Enum.any?(&(&1["callback_data"] == "allbert:v1:approve:conf_123"))
    end
  end

  describe "adapter" do
    test "starts idle when disabled" do
      server = :"telegram-disabled-#{System.unique_integer([:positive])}"
      start_supervised!({Adapter, name: server, auto_poll?: false})

      assert Adapter.poll_once(server) == {:error, :disabled}
    end

    test "poll_once inserts events, rejects unmapped text, and advances offset" do
      configure_telegram!()

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/bottoken/getUpdates"
        query = Query.decode(conn.query_string)
        assert query["offset"] == "1"
        json(conn, %{"ok" => true, "result" => [text_update(200), callback_update(201)]})
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/bottoken/answerCallbackQuery"
        json(conn, %{"ok" => true, "result" => true})
      end)

      server = :"telegram-poll-#{System.unique_integer([:positive])}"

      start_telegram_server!(server)

      assert {:ok, %{processed: 0, duplicates: 0, rejected: 2, failed: 0}} =
               Adapter.poll_once(server)

      assert Channels.get_event_by_external_id("telegram", "200").status == "rejected"
      assert Channels.get_event_by_external_id("telegram", "201").direction == "callback"
    end

    test "skips duplicate updates without resubmitting events" do
      configure_telegram!()
      insert_update_response(200)

      server = :"telegram-duplicate-#{System.unique_integer([:positive])}"

      start_telegram_server!(server)

      assert {:ok, %{rejected: 1}} = Adapter.poll_once(server)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/bottoken/getUpdates"
        json(conn, %{"ok" => true, "result" => [text_update(200)]})
      end)

      assert {:ok, %{processed: 0, duplicates: 1}} = Adapter.poll_once(server)
    end

    test "mapped text submits through runtime, sends response, and updates event metadata" do
      configure_telegram!(identity_map: [%{external_user_id: "123", user_id: "alice"}])
      configure_runtime!()

      Req.Test.stub(__MODULE__, fn
        %{request_path: "/bottoken/getUpdates"} = conn ->
          json(conn, %{"ok" => true, "result" => [text_update(210, "/new hello from tg")]})

        %{request_path: "/bottoken/sendMessage"} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)
          assert decoded["chat_id"] == "456"
          assert decoded["text"] =~ "Runtime response: hello from tg"
          json(conn, %{"ok" => true, "result" => %{"message_id" => 99}})
      end)

      server = :"telegram-runtime-#{System.unique_integer([:positive])}"
      start_telegram_server!(server)

      assert {:ok, %{processed: 1, rejected: 0, failed: 0}} = Adapter.poll_once(server)

      event = Channels.get_event_by_external_id("telegram", "210")
      assert event.status == "processed"
      assert event.user_id == "alice"
      assert String.starts_with?(event.session_id, "ch_tg_")
      assert String.starts_with?(event.thread_id, "thr_")
      assert is_binary(event.input_signal_id)
      assert is_binary(event.trace_id)

      assert {:ok, %{messages: messages}} = Conversations.show_thread("alice", event.thread_id)

      assert Enum.map(messages, & &1.content) == [
               "hello from tg",
               "Runtime response: hello from tg"
             ]

      assert_received {:runtime_request, %{channel: "telegram", user_id: "alice"} = request}
      assert request.metadata.external_event_id == "210"
      assert request.metadata.external_chat_id == "456"
    end

    test "confirmation callbacks resolve through registered actions with resolver metadata" do
      configure_telegram!(identity_map: [%{external_user_id: "123", user_id: "alice"}])
      assert {:ok, confirmation} = create_confirmation!("conf_tg_deny", "telegram")

      Req.Test.stub(__MODULE__, fn
        %{request_path: "/bottoken/getUpdates"} = conn ->
          json(conn, %{
            "ok" => true,
            "result" => [callback_update(220, "allbert:v1:deny:#{confirmation["id"]}")]
          })

        %{request_path: "/bottoken/sendMessage"} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)
          assert decoded["chat_id"] == "456"
          assert decoded["text"] =~ "denied"
          json(conn, %{"ok" => true, "result" => %{"message_id" => 100}})

        %{request_path: "/bottoken/answerCallbackQuery"} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body)["callback_query_id"] == "callback-1"
          json(conn, %{"ok" => true, "result" => true})
      end)

      server = :"telegram-callback-#{System.unique_integer([:positive])}"
      start_telegram_server!(server)

      assert {:ok, %{processed: 1, rejected: 0}} = Adapter.poll_once(server)

      assert {:ok, resolved} = Confirmations.read(confirmation["id"])
      assert resolved["status"] == "denied"
      assert resolved["operator_resolution"]["resolver_actor"] == "alice"
      assert resolved["operator_resolution"]["resolver_channel"] == "telegram"

      assert resolved["operator_resolution"]["resolver_metadata"]["callback_query_id"] ==
               "callback-1"

      event = Channels.get_event_by_external_id("telegram", "220")
      assert event.direction == "callback"
      assert event.status == "processed"
      assert event.user_id == "alice"
      assert String.starts_with?(event.session_id, "ch_tg_")
      assert is_binary(event.input_signal_id)
    end

    test "malformed confirmation callbacks are rejected and acknowledged" do
      configure_telegram!(identity_map: [%{external_user_id: "123", user_id: "alice"}])

      Req.Test.stub(__MODULE__, fn
        %{request_path: "/bottoken/getUpdates"} = conn ->
          json(conn, %{"ok" => true, "result" => [callback_update(221, "bad-callback")]})

        %{request_path: "/bottoken/answerCallbackQuery"} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body)["text"] == "Unsupported confirmation button."
          json(conn, %{"ok" => true, "result" => true})
      end)

      server = :"telegram-bad-callback-#{System.unique_integer([:positive])}"
      start_telegram_server!(server)

      assert {:ok, %{rejected: 1}} = Adapter.poll_once(server)
      event = Channels.get_event_by_external_id("telegram", "221")
      assert event.status == "rejected"
      assert event.reason == ":malformed_callback_data"
    end

    test "show confirmation callback renders current state without resolving it" do
      configure_telegram!(identity_map: [%{external_user_id: "123", user_id: "alice"}])
      assert {:ok, confirmation} = create_confirmation!("conf_tg_show", "telegram")

      Req.Test.stub(__MODULE__, fn
        %{request_path: "/bottoken/getUpdates"} = conn ->
          json(conn, %{
            "ok" => true,
            "result" => [callback_update(222, "allbert:v1:show:#{confirmation["id"]}")]
          })

        %{request_path: "/bottoken/sendMessage"} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body)["text"] =~ "pending"
          json(conn, %{"ok" => true, "result" => %{"message_id" => 101}})

        %{request_path: "/bottoken/answerCallbackQuery"} = conn ->
          json(conn, %{"ok" => true, "result" => true})
      end)

      server = :"telegram-show-callback-#{System.unique_integer([:positive])}"
      start_telegram_server!(server)

      assert {:ok, %{processed: 1}} = Adapter.poll_once(server)
      assert {:ok, pending} = Confirmations.read(confirmation["id"])
      assert pending["status"] == "pending"
    end

    test "derives restart offset from stored channel events" do
      configure_telegram!()

      assert {:ok, _event} =
               Channels.create_event(%{
                 channel: "telegram",
                 provider: "telegram_bot_api",
                 direction: "inbound",
                 external_event_id: "300",
                 status: "received"
               })

      Req.Test.expect(__MODULE__, fn conn ->
        query = Query.decode(conn.query_string)
        assert query["offset"] == "301"
        json(conn, %{"ok" => true, "result" => []})
      end)

      server = :"telegram-offset-#{System.unique_integer([:positive])}"

      start_telegram_server!(server)

      assert {:ok, %{processed: 0}} = Adapter.poll_once(server)
    end

    test "backs off on provider errors" do
      configure_telegram!()

      Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :timeout))

      server = :"telegram-error-#{System.unique_integer([:positive])}"

      start_telegram_server!(server)

      assert {:error, {:transport_error, :timeout}} = Adapter.poll_once(server)
    end
  end

  defp configure_telegram!(opts \\ []) do
    assert {:ok, _secret} =
             Secrets.put_secret("secret://channels/telegram/bot_token", "token", %{audit?: false})

    assert {:ok, _setting} = Settings.put("channels.telegram.enabled", true, %{audit?: false})

    identity_map = Keyword.get(opts, :identity_map, [])

    assert {:ok, _setting} =
             Settings.put("channels.telegram.identity_map", identity_map, %{audit?: false})
  end

  defp configure_runtime! do
    parent = self()

    Application.put_env(:allbert_assist, Trace, enabled: true)

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:runtime_request, request})
        {:ok, %{message: "Runtime response: #{request.text}", status: :completed}}
      end
    )
  end

  defp insert_update_response(update_id) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/bottoken/getUpdates"
      json(conn, %{"ok" => true, "result" => [text_update(update_id)]})
    end)
  end

  defp start_telegram_server!(server) do
    pid =
      start_supervised!(
        {Adapter, name: server, auto_poll?: false, req_options: [plug: {Req.Test, __MODULE__}]}
      )

    Req.Test.allow(__MODULE__, self(), pid)
    pid
  end

  defp text_update(update_id, text \\ "hello") do
    %{
      "update_id" => update_id,
      "message" => %{
        "message_id" => 10,
        "from" => %{"id" => 123},
        "chat" => %{"id" => 456, "type" => "private"},
        "text" => text
      }
    }
  end

  defp callback_update(update_id, data \\ "allbert:v1:show:conf_1") do
    %{
      "update_id" => update_id,
      "callback_query" => %{
        "id" => "callback-1",
        "from" => %{"id" => 123},
        "message" => %{"chat" => %{"id" => 456}},
        "data" => data
      }
    }
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

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
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
