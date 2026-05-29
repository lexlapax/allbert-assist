defmodule AllbertAssist.Surface.EncoderTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Encoder

  test "to_a2ui is an explicit not-implemented adapter stub" do
    surface = %Surface{
      id: :agent,
      app_id: :allbert,
      label: "Allbert Chat",
      path: "/workspace",
      kind: :chat,
      status: :available,
      fallback_text: "Allbert chat is available at /workspace."
    }

    assert {:error, :not_implemented} = Encoder.to_a2ui(surface)
  end
end
