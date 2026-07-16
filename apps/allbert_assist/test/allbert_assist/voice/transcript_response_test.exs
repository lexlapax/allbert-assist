defmodule AllbertAssist.Voice.TranscriptResponseTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Voice.TranscriptResponse

  test "extracts common OpenAI-compatible transcript fields" do
    assert {:ok, "hello"} = TranscriptResponse.transcript_text(%{"text" => " hello "})
    assert {:ok, "hello"} = TranscriptResponse.transcript_text(%{"transcript" => "hello"})
  end

  test "extracts Gemini output and candidate text shapes" do
    assert {:ok, "hello"} = TranscriptResponse.transcript_text(%{"output_text" => " hello "})
    assert {:ok, "hello"} = TranscriptResponse.transcript_text(%{"outputText" => "hello"})

    assert {:ok, "hello world"} =
             TranscriptResponse.transcript_text(%{
               "candidates" => [
                 %{
                   "content" => %{
                     "parts" => [
                       %{"text" => "hello "},
                       %{"text" => "world"}
                     ]
                   }
                 }
               ]
             })
  end

  test "extracts streamed or segmented transcript text" do
    assert {:ok, "hello world"} =
             TranscriptResponse.transcript_text([
               %{"text" => "hello "},
               %{"text" => "world"}
             ])

    assert {:ok, "hello world"} =
             TranscriptResponse.transcript_text(%{
               "segments" => [
                 %{"text" => "hello"},
                 %{"text" => "world"}
               ]
             })
  end

  test "distinguishes empty transcript from missing transcript" do
    assert {:error, :empty_voice_transcript} =
             TranscriptResponse.transcript_text(%{"text" => " "})

    assert {:error, :missing_voice_transcript} = TranscriptResponse.transcript_text(%{})
  end
end
