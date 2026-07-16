defmodule AllbertAssist.Channels.TelegramTest do
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Telegram.Adapter
  alias AllbertAssist.Channels.Telegram.Client
  alias AllbertAssist.Channels.Telegram.Parser
  alias AllbertAssist.Channels.Telegram.Renderer
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
    PluginRegistry.clear()

    assert {:ok, "allbert.telegram"} =
             PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)

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
    test "parses text messages" do
      assert {:text_message, fields} = Parser.parse_update(text_update(100))
      assert fields.external_event_id == "100"
      assert fields.external_user_id == "123"
      assert fields.external_chat_id == "456"
      assert fields.external_message_id == "10"
      assert fields.message_thread_id == nil
      assert fields.reply_to_message_id == nil
      assert fields.text == "hello"
    end

    test "parses topic and reply metadata for threaded placement" do
      update =
        text_update(104, "reply in topic", 22)
        |> put_in(["message", "message_thread_id"], 7)
        |> put_in(["message", "reply_to_message"], %{"message_id" => 21})

      assert {:text_message, fields} = Parser.parse_update(update)
      assert fields.external_message_id == "22"
      assert fields.message_thread_id == "7"
      assert fields.reply_to_message_id == "21"
    end

    test "parses voice notes" do
      assert {:voice_message, fields} = Parser.parse_update(voice_update(103))
      assert fields.external_event_id == "103"
      assert fields.external_user_id == "123"
      assert fields.external_chat_id == "456"
      assert fields.external_message_id == "10"
      assert fields.voice_file_id == "voice-file-103"
      assert fields.voice_file_unique_id == "voice-unique-103"
      assert fields.voice_duration_seconds == 2
      assert fields.voice_mime_type == "audio/ogg"
      assert fields.voice_file_size == 16
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
        assert conn.request_path == "/bottoken/sendMessage"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["chat_id"] == "456"
        assert decoded["text"] == "threaded"
        assert decoded["reply_parameters"] == %{"message_id" => "10"}
        assert decoded["message_thread_id"] == "7"
        json(conn, %{"ok" => true, "result" => %{"message_id" => 100}})
      end)

      assert {:ok, %{"message_id" => 100}} =
               Client.send_message("token", "456", "threaded",
                 reply_to_message_id: "10",
                 message_thread_id: "7",
                 plug: {Req.Test, __MODULE__}
               )

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/bottoken/answerCallbackQuery"
        json(conn, %{"ok" => true, "result" => true})
      end)

      assert {:ok, true} =
               Client.answer_callback_query("token", "callback-1", "ok",
                 plug: {Req.Test, __MODULE__}
               )
    end

    test "gets and downloads Telegram files" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/bottoken/getFile"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["file_id"] == "voice-file-103"

        json(conn, %{
          "ok" => true,
          "result" => %{"file_path" => "voice/hello.ogg", "file_size" => 16}
        })
      end)

      assert {:ok, %{"file_path" => "voice/hello.ogg", "file_size" => 16}} =
               Client.get_file("token", "voice-file-103", plug: {Req.Test, __MODULE__})

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/file/bottoken/voice/hello.ogg"

        conn
        |> Plug.Conn.put_resp_content_type("audio/ogg")
        |> Plug.Conn.send_resp(200, "voice fixture")
      end)

      assert {:ok, "voice fixture"} =
               Client.download_file("token", "voice/hello.ogg", plug: {Req.Test, __MODULE__})

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/file/bottoken/voice/large.ogg"

        conn
        |> Plug.Conn.put_resp_content_type("audio/ogg")
        |> Plug.Conn.send_resp(200, "oversized voice fixture")
      end)

      assert {:error, {:telegram_file_too_large, _size, 4}} =
               Client.download_file("token", "voice/large.ogg",
                 max_response_bytes: 4,
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

    test "keeps inline keyboard callback data within Telegram provider limits" do
      assert {:ok, confirmation} = create_confirmation!(nil, "telegram")

      handoff = %{
        confirmation_id: confirmation["id"],
        status: :pending,
        target_action: %{action: %{name: "run_skill_script"}}
      }

      assert {:ok, [_text], %{"inline_keyboard" => buttons}} =
               Renderer.render_response(%{approval_handoff: handoff})

      buttons
      |> List.flatten()
      |> Enum.each(fn button ->
        assert is_binary(button["text"])
        assert byte_size(button["callback_data"]) in 1..64
      end)
    end

    test "falls back to typed commands when callback data would exceed provider limit" do
      long_id = "conf_" <> String.duplicate("long", 20)

      handoff = %{
        confirmation_id: long_id,
        status: :pending,
        target_action: %{action: %{name: "run_skill_script"}}
      }

      assert {:ok, [text], nil} = Renderer.render_response(%{approval_handoff: handoff})

      assert text =~ "Reply with one exact command:"
      assert text =~ "ALLBERT:APPROVE:#{long_id}"
      assert text =~ "ALLBERT:DENY:#{long_id}"
      assert text =~ "ALLBERT:SHOW:#{long_id}"
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

      assert {:ok, [text], _keyboard} = Renderer.render_response(%{approval_handoff: handoff})

      assert text =~ "Objective: #{objective.id}"
      assert text =~ "Title: Analyze AAPL"
      assert text =~ "Status: :cancelled"
      assert text =~ "Note: objective is now :cancelled"
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

    test "resumes duplicate updates left in received state" do
      configure_telegram!(identity_map: [%{external_user_id: "123", user_id: "alice"}])
      configure_runtime!()

      assert {:ok, _event} =
               Channels.create_event(%{
                 channel: "telegram",
                 provider: "telegram_bot_api",
                 direction: "inbound",
                 external_event_id: "211",
                 external_user_id: "123",
                 external_chat_id: "456",
                 external_message_id: "10",
                 status: "received"
               })

      Req.Test.stub(__MODULE__, fn
        %{request_path: "/bottoken/getUpdates"} = conn ->
          json(conn, %{"ok" => true, "result" => [text_update(211, "/new resumed tg")]})

        %{request_path: "/bottoken/sendMessage"} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)
          assert decoded["text"] =~ "Runtime response: resumed tg"
          json(conn, %{"ok" => true, "result" => %{"message_id" => 99}})
      end)

      server = :"telegram-resume-received-#{System.unique_integer([:positive])}"
      start_telegram_server!(server)

      assert {:ok, %{processed: 1, duplicates: 0, rejected: 0, failed: 0}} =
               Adapter.poll_once(server)

      event = Channels.get_event_by_external_id("telegram", "211")
      assert event.status == "processed"
      assert event.user_id == "alice"
      assert String.starts_with?(event.thread_id, "thr_")
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
          assert decoded["reply_parameters"] == %{"message_id" => "10"}
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
      assert request.provider_message_id == "10"
      assert request.channel_thread_ref.channel == "telegram"
      assert request.channel_thread_ref.receiver_account_ref =~ "telegram:bot:ptk_"
      assert request.channel_thread_ref.receiver_account_ref =~ ":chat:456"

      assert request.channel_thread_ref.provider_thread_ref["provider_thread_root"] ==
               "message:10"

      assert request.metadata.external_event_id == "210"
      assert request.metadata.external_chat_id == "456"

      refs =
        ConversationMessageRef
        |> where([ref], ref.channel == "telegram")
        |> order_by([ref], asc: ref.direction)
        |> Repo.all()

      assert Enum.any?(refs, &(&1.direction == "in" and &1.provider_message_id == "10"))
      assert Enum.any?(refs, &(&1.direction == "out" and &1.provider_message_id == "99"))
    end

    test "suppresses Telegram echoes before runtime resubmission" do
      configure_telegram!(identity_map: [%{external_user_id: "123", user_id: "alice"}])
      configure_runtime!()

      Req.Test.stub(__MODULE__, fn
        %{request_path: "/bottoken/getUpdates", query_string: query_string} = conn ->
          query = Query.decode(query_string)

          updates =
            case query["offset"] do
              "1" -> [text_update(240, "first")]
              "241" -> [text_update(241, "bot echo", 99)]
            end

          json(conn, %{"ok" => true, "result" => updates || []})

        %{request_path: "/bottoken/sendMessage"} = conn ->
          json(conn, %{"ok" => true, "result" => %{"message_id" => 99}})
      end)

      server = :"telegram-echo-#{System.unique_integer([:positive])}"
      start_telegram_server!(server)

      assert {:ok, %{processed: 1}} = Adapter.poll_once(server)
      assert_received {:runtime_request, %{text: "first"}}

      assert {:ok, %{processed: 0, rejected: 1, failed: 0}} = Adapter.poll_once(server)
      refute_received {:runtime_request, %{text: "bot echo"}}

      event = Channels.get_event_by_external_id("telegram", "241")
      assert event.status == "rejected"
      assert event.reason == ":echo_suppressed"
    end

    test "mapped voice note downloads, transcribes, and submits text through runtime" do
      configure_telegram!(identity_map: [%{external_user_id: "123", user_id: "alice"}])
      enable_voice!()
      configure_runtime!()

      Req.Test.stub(__MODULE__, fn
        %{request_path: "/bottoken/getUpdates"} = conn ->
          json(conn, %{"ok" => true, "result" => [voice_update(230)]})

        %{request_path: "/bottoken/getFile"} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body)["file_id"] == "voice-file-230"

          json(conn, %{
            "ok" => true,
            "result" => %{"file_path" => "voice/hello.ogg", "file_size" => 16}
          })

        %{request_path: "/file/bottoken/voice/hello.ogg"} = conn ->
          conn
          |> Plug.Conn.put_resp_content_type("audio/ogg")
          |> Plug.Conn.send_resp(200, "telegram voice fixture")

        %{request_path: "/bottoken/sendMessage"} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          decoded = Jason.decode!(body)
          assert decoded["chat_id"] == "456"
          assert decoded["text"] =~ "Runtime response: transcribed fixture audio"
          json(conn, %{"ok" => true, "result" => %{"message_id" => 130}})
      end)

      server = :"telegram-voice-#{System.unique_integer([:positive])}"
      start_telegram_server!(server)

      assert {:ok, %{processed: 1, rejected: 0, failed: 0}} = Adapter.poll_once(server)

      event = Channels.get_event_by_external_id("telegram", "230")
      assert event.status == "processed"
      assert event.user_id == "alice"
      assert String.starts_with?(event.session_id, "ch_tg_")
      assert is_binary(event.thread_id)

      assert_received {:runtime_request, %{channel: "telegram", user_id: "alice"} = request}
      assert request.text =~ "transcribed fixture audio"
      assert request.metadata.voice.provider_profile == "voice_stt_fake"
      assert request.metadata.telegram_voice.file_id == "voice-file-230"
      assert request.metadata.telegram_voice.file_unique_id == "voice-unique-230"
      assert request.metadata.telegram_voice.duration_seconds == 2
      assert request.metadata.telegram_voice.file_size == 16
      refute inspect(request.metadata) =~ "telegram voice fixture"
    end

    test "voice notes honor voice.audio.max_bytes before file fetch" do
      configure_telegram!()
      assert {:ok, _setting} = Settings.put("voice.audio.max_bytes", 8, %{audit?: false})

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/bottoken/getUpdates"
        json(conn, %{"ok" => true, "result" => [voice_update(231)]})
      end)

      server = :"telegram-voice-max-#{System.unique_integer([:positive])}"
      start_telegram_server!(server)

      assert {:ok, %{processed: 0, rejected: 1, failed: 0}} = Adapter.poll_once(server)

      event = Channels.get_event_by_external_id("telegram", "231")
      assert event.status == "rejected"
      assert event.reason == "{:telegram_voice_too_large, 16, 8}"
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

  defp enable_voice! do
    assert {:ok, _resolved} = Settings.put("voice.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.speech_to_text", ["voice_stt_fake"], %{
               audit?: false
             })
  end

  defp configure_runtime! do
    parent = self()

    AllbertAssist.TraceTestSupport.enable_trace_default!()

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

  defp text_update(update_id, text \\ "hello", message_id \\ 10) do
    %{
      "update_id" => update_id,
      "message" => %{
        "message_id" => message_id,
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

  defp voice_update(update_id) do
    %{
      "update_id" => update_id,
      "message" => %{
        "message_id" => 10,
        "from" => %{"id" => 123},
        "chat" => %{"id" => 456, "type" => "private"},
        "voice" => %{
          "file_id" => "voice-file-#{update_id}",
          "file_unique_id" => "voice-unique-#{update_id}",
          "duration" => 2,
          "mime_type" => "audio/ogg",
          "file_size" => 16
        }
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
