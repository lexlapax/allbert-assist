defmodule AllbertAssist.Artifacts.MediaRetentionTest do
  use ExUnit.Case, async: true
  @moduletag :home_fs_serial

  alias AllbertAssist.Artifacts.MediaRetention

  test "mime prefers normalized explicit content type" do
    assert MediaRetention.mime(%{"content_type" => " Image/PNG; charset=utf-8 "}) == "image/png"
  end

  test "mime falls back to known file extensions" do
    assert MediaRetention.mime(%{filename: "clip.WAV"}) == "audio/wav"
    assert MediaRetention.mime(%{path: "/tmp/frame.jpeg"}) == "image/jpeg"
  end

  test "mime falls back to octet stream for unknown or invalid attrs" do
    assert MediaRetention.mime(%{filename: "archive.bin"}) == "application/octet-stream"
    assert MediaRetention.mime(:invalid) == "application/octet-stream"
  end
end
