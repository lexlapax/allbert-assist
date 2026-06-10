defmodule AllbertSlack.RendererTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Channels.Slack.Renderer

  test "chunks ordinary Slack messages at the configured Slack limit" do
    assert {:ok, [first, second]} =
             Renderer.render_response(%{message: String.duplicate("x", 3001)})

    assert byte_size(first.text) == 3000
    assert second.text == "x"
  end

  test "renders approval handoff as Block Kit button actions" do
    assert {:ok, [message]} =
             Renderer.render_response(%{
               approval_handoff: %{
                 confirmation_id: "conf_123",
                 summary: "Run the command?"
               }
             })

    assert message.text =~ "conf_123"
    assert [%{type: "section"}, %{type: "actions", elements: buttons}] = message.blocks

    assert Enum.any?(buttons, fn button ->
             button.type == "button" and button.text.text == "Approve" and
               button.action_id == "allbert:v1:approve:conf_123"
           end)
  end
end
