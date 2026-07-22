defmodule AllbertAssistWeb.PublicProtocol.OpenAIFanoutTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.PublicProtocol.OpenAI.Mapping

  @source Path.expand(
            "../../../lib/allbert_assist_web/controllers/public_protocol/openai_controller.ex",
            __DIR__
          )

  test "controller uses genuine chunked kickoff-before-ack continuation" do
    source = File.read!(@source)

    assert source =~ "send_chunked(200)"
    assert source =~ "chunk(Mapping.sse_chunk(kickoff))"
    assert source =~ "persist_and_acknowledge(event, response)"
    assert source =~ "Runtime.await_fanout"
    assert source =~ "data: [DONE]"
  end

  test "SSE chunks do not close the stream unless requested" do
    completion = %{
      "id" => "chatcmpl_test",
      "created" => 1,
      "model" => "local",
      "choices" => [
        %{
          "message" => %{"content" => "kickoff"}
        }
      ]
    }

    refute Mapping.sse_chunk(completion) =~ "[DONE]"
    assert Mapping.sse_chunk(completion, finish?: true) =~ ~s("finish_reason":"stop")
  end
end
