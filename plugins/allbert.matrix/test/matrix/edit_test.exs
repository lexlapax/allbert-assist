defmodule AllbertMatrix.EditTest do
  use ExUnit.Case, async: true

  @moduletag :external_runtime_serial

  import Plug.Conn

  alias AllbertAssist.Channels.Matrix.Client

  setup {Req.Test, :verify_on_exit!}

  test "m.replace sends a whitelisted PUT relation to the original event" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "PUT"

      assert conn.request_path ==
               "/_matrix/client/v3/rooms/%21room%3Aexample.test/send/m.room.message/txn-2"

      {:ok, body, conn} = read_body(conn)
      content = Jason.decode!(body)
      assert content["m.relates_to"] == %{"rel_type" => "m.replace", "event_id" => "$event-1"}
      assert content["m.new_content"] == %{"msgtype" => "m.text", "body" => "working"}
      json(conn, %{"event_id" => "$edit-2"})
    end)

    assert {:ok, %{"event_id" => "$edit-2"}} =
             Client.replace_message(
               "https://matrix.example.test",
               "token",
               "!room:example.test",
               "txn-2",
               "$event-1",
               "working",
               plug: {Req.Test, __MODULE__}
             )
  end

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end
end
