defmodule AllbertAssist.Channels.TelegramTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Telegram.Adapter
  alias AllbertAssist.Channels.Telegram.Client
  alias AllbertAssist.Channels.Telegram.Parser
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_env = Map.new(["ALLBERT_HOME", "ALLBERT_HOME_DIR"], &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(Map.keys(original_env), &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home =
      Path.join(System.tmp_dir!(), "allbert-telegram-test-#{System.unique_integer([:positive])}")

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
        query = Plug.Conn.Query.decode(conn.query_string)
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

  describe "adapter" do
    test "starts idle when disabled" do
      server = :"telegram-disabled-#{System.unique_integer([:positive])}"
      start_supervised!({Adapter, name: server, auto_poll?: false})

      assert Adapter.poll_once(server) == {:error, :disabled}
    end

    test "poll_once inserts received events and advances offset" do
      configure_telegram!()

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/bottoken/getUpdates"
        query = Plug.Conn.Query.decode(conn.query_string)
        assert query["offset"] == "1"
        json(conn, %{"ok" => true, "result" => [text_update(200), callback_update(201)]})
      end)

      server = :"telegram-poll-#{System.unique_integer([:positive])}"

      start_telegram_server!(server)

      assert {:ok, %{processed: 2, duplicates: 0, rejected: 0, failed: 0}} =
               Adapter.poll_once(server)

      assert Channels.get_event_by_external_id("telegram", "200").direction == "inbound"
      assert Channels.get_event_by_external_id("telegram", "201").direction == "callback"
    end

    test "skips duplicate updates without resubmitting events" do
      configure_telegram!()
      insert_update_response(200)

      server = :"telegram-duplicate-#{System.unique_integer([:positive])}"

      start_telegram_server!(server)

      assert {:ok, %{processed: 1}} = Adapter.poll_once(server)

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/bottoken/getUpdates"
        json(conn, %{"ok" => true, "result" => [text_update(200)]})
      end)

      assert {:ok, %{processed: 0, duplicates: 1}} = Adapter.poll_once(server)
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
        query = Plug.Conn.Query.decode(conn.query_string)
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

  defp configure_telegram! do
    assert {:ok, _secret} =
             Secrets.put_secret("secret://channels/telegram/bot_token", "token", %{audit?: false})

    assert {:ok, _setting} = Settings.put("channels.telegram.enabled", true, %{audit?: false})
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

  defp text_update(update_id) do
    %{
      "update_id" => update_id,
      "message" => %{
        "message_id" => 10,
        "from" => %{"id" => 123},
        "chat" => %{"id" => 456},
        "text" => "hello"
      }
    }
  end

  defp callback_update(update_id) do
    %{
      "update_id" => update_id,
      "callback_query" => %{
        "id" => "callback-1",
        "from" => %{"id" => 123},
        "message" => %{"chat" => %{"id" => 456}},
        "data" => "allbert:v1:show:conf_1"
      }
    }
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
