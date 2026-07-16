defmodule AllbertAssist.Plugins.WhatsApp.RendererTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Channels.WhatsApp.Renderer

  test "renders plain WhatsApp text chunks" do
    assert {:ok, [%{type: :text, body: "hello"}]} =
             Renderer.render_response(%{message: "hello"})
  end

  test "renders approval handoff as in-session buttons" do
    assert {:ok, [%{type: :interactive_buttons, body: body, buttons: buttons}]} =
             Renderer.render_response(%{
               approval_handoff: %{
                 confirmation_id: "confirm_123",
                 summary: "Approve request?"
               }
             })

    assert body =~ "Approval"
    assert Enum.map(buttons, & &1.title) == ["Approve", "Deny", "Show"]
    assert Enum.all?(buttons, &(byte_size(&1.id) <= 256))
    assert Enum.all?(buttons, &(byte_size(&1.title) <= 20))
  end

  test "falls back to typed commands when button rendering is disabled" do
    assert {:ok, [%{type: :text, body: body}]} =
             Renderer.render_response(
               %{
                 approval_handoff: %{
                   confirmation_id: "confirm_123",
                   summary: "Approve request?"
                 }
               },
               render_buttons: false
             )

    assert body =~ "ALLBERT:APPROVE:confirm_123"
    assert body =~ "ALLBERT:DENY:confirm_123"
  end
end
