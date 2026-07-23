defmodule AllbertDiscord.EditTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.Channels.Discord.Client

  test "PATCH updates the existing Discord message" do
    assert {:ok, %{"id" => "message-1", "content" => "working"}} =
             Client.update_message(
               "secret://channels/discord/bot_token",
               "channel-1",
               "message-1",
               %{content: "working"},
               mode: :stub,
               capture_to: self()
             )

    assert_receive {:discord_update_message, "channel-1", "message-1", %{content: "working"}}

    request =
      Client.update_message_request(
        "secret://channels/discord/bot_token",
        "channel-1",
        "message-1",
        %{content: "working"}
      )

    assert request.method == :patch
    assert request.path == "/channels/channel-1/messages/message-1"
    assert request.redacted_headers == [{"authorization", "[REDACTED]"}]
  end
end
