defmodule AllbertAssist.Plugins.Matrix.RendererTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Channels.Matrix.Renderer

  test "renders plain Matrix text content" do
    assert %{"msgtype" => "m.text", "body" => "hello"} = Renderer.message_content("hello")
  end

  test "renders Matrix thread relation with reply fallback" do
    content =
      Renderer.message_content("hello", %{
        thread_root_event_id: "$root",
        reply_to_event_id: "$parent"
      })

    assert content["m.relates_to"] == %{
             "rel_type" => "m.thread",
             "event_id" => "$root",
             "m.in_reply_to" => %{"event_id" => "$parent"},
             "is_falling_back" => true
           }
  end
end
