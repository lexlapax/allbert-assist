defmodule AllbertSlack.RendererTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

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

    # Slack rejects `"style": null` with {:slack_error, "invalid_blocks"}, which
    # silently dropped the whole approval card in live validation. A button must
    # either omit :style or carry a valid Slack value — never nil.
    for button <- buttons do
      case Map.fetch(button, :style) do
        :error -> :ok
        {:ok, style} -> assert style in ["primary", "danger"]
      end
    end

    # the non-approve/deny ("show"/details) button must omit :style entirely
    assert Enum.any?(buttons, fn button -> not Map.has_key?(button, :style) end)
  end

  test "falls back to typed commands when Slack buttons are disabled" do
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

    assert message.text =~ "ALLBERT:APPROVE:conf_123"
    refute Map.has_key?(message, :blocks)
  end
end
