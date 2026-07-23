defmodule AllbertSlack.EditTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.Channels.Slack.Client

  test "chat.update targets the existing Slack timestamp" do
    payload = %{channel: "channel-1", ts: "1718040000.000100", text: "working"}

    assert {:ok, %{"ts" => "1718040000.000100", "text" => "working"}} =
             Client.chat_update("secret://channels/slack/bot_token", payload,
               mode: :stub,
               capture_to: self()
             )

    assert_receive {:slack_chat_update, ^payload}

    request = Client.chat_update_request("secret://channels/slack/bot_token", payload)
    assert request.method == :post
    assert request.path == "/chat.update"
    assert request.redacted_headers == [{"authorization", "[REDACTED]"}]
  end
end
