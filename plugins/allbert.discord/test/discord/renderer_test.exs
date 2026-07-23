defmodule AllbertDiscord.RendererTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Channels.Discord.Renderer

  test "chunks ordinary Discord messages at the Discord limit" do
    assert {:ok, [first, second]} =
             Renderer.render_response(%{message: String.duplicate("x", 2001)})

    assert byte_size(first.content) == 2000
    assert second.content == "x"
  end

  test "renders the one-time notify offer as a consent button" do
    assert {:ok, [message]} =
             Renderer.render_response(%{
               message: "Fan-out started.",
               notify_offer: %{channel: "discord", user_id: "alice"}
             })

    assert [%{components: [button]}] = message.components
    assert button.custom_id == "ALLBERT:NOTIFY:ON"
    assert button.label == "Enable notifications"
  end

  test "renders approval handoff as Discord button components" do
    assert {:ok, [message]} =
             Renderer.render_response(%{
               approval_handoff: %{
                 confirmation_id: "conf_123",
                 summary: "Run the command?"
               }
             })

    assert message.content =~ "conf_123"
    assert [%{type: 1, components: buttons}] = message.components

    assert Enum.any?(buttons, fn button ->
             button.type == 2 and button.label == "Approve" and
               button.custom_id == "allbert:v1:approve:conf_123"
           end)
  end

  test "falls back to typed commands when Discord buttons are disabled" do
    assert {:ok, [message]} =
             Renderer.render_response(
               %{
                 approval_handoff: %{
                   confirmation_id: "conf_123",
                   summary: "Run the command?"
                 }
               },
               render_buttons: false
             )

    assert message.content =~ "ALLBERT:APPROVE:conf_123"
    refute Map.has_key?(message, :components)
  end
end
