defmodule AllbertAssist.Plugins.Telegram.EditTest do
  use ExUnit.Case, async: true

  @moduletag :external_runtime_serial

  import Plug.Conn

  alias AllbertAssist.Channels.Telegram.Client

  setup {Req.Test, :verify_on_exit!}

  test "editMessageText updates the existing provider message" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/bottoken/editMessageText"
      {:ok, body, conn} = read_body(conn)

      assert Jason.decode!(body) == %{
               "chat_id" => "chat-1",
               "message_id" => 101,
               "text" => "working"
             }

      json(conn, %{
        "ok" => true,
        "result" => %{"message_id" => 101, "text" => "working"}
      })
    end)

    assert {:ok, %{"message_id" => 101}} =
             Client.edit_message("token", "chat-1", 101, "working", plug: {Req.Test, __MODULE__})
  end

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end
end
