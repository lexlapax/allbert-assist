defmodule AllbertAssistWeb.PublicProtocol.OpenAIFanoutTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.PublicProtocol.OpenAI.FanoutWait
  alias AllbertAssist.PublicProtocol.OpenAI.Mapping

  @source Path.expand(
            "../../../lib/allbert_assist_web/controllers/public_protocol/openai_controller.ex",
            __DIR__
          )

  # v1.4 M3 (26419c859) relocated the test-injectable fan-out awaiter out of
  # this controller (a Mix.env() branch does not belong in the web layer) and
  # into the shared `FanoutWait` module. The controller now reaches the real
  # continuation through `FanoutWait.await/3`, which delegates to
  # `Runtime.await_fanout/3` in every environment except a test-injected
  # awaiter override -- so the "genuine join, not a stub" guarantee this test
  # encodes now spans both files.
  test "controller uses genuine chunked kickoff-before-ack continuation" do
    source = File.read!(@source)

    assert source =~ "send_chunked(200)"
    assert source =~ "chunk(Mapping.sse_chunk(kickoff))"
    assert source =~ "persist_and_acknowledge(event, response, epoch)"
    assert source =~ "FanoutWait.await("
    assert source =~ "Fanout.format_report(report)"
    refute source =~ "report.children"
    refute source =~ "Fanout.report_child_detail"
    assert source =~ "data: [DONE]"

    fanout_wait_source =
      FanoutWait.__info__(:compile) |> Keyword.fetch!(:source) |> to_string() |> File.read!()

    assert fanout_wait_source =~ "Runtime.await_fanout"
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
