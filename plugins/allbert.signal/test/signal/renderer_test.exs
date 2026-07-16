defmodule AllbertAssist.Plugins.Signal.RendererTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Channels.Signal.Renderer

  test "renders plain Signal text chunks" do
    assert {:ok, ["hello"]} = Renderer.render_response(%{message: "hello"})
  end

  test "renders approval handoff as typed commands" do
    assert {:ok, [body]} =
             Renderer.render_response(%{
               approval_handoff: %{
                 confirmation_id: "confirm_123",
                 summary: "Approve request?"
               }
             })

    assert body =~ "ALLBERT:APPROVE:confirm_123"
    assert body =~ "ALLBERT:DENY:confirm_123"
    assert body =~ "ALLBERT:SHOW:confirm_123"
  end
end
