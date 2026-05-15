defmodule AllbertAssist.Surface.EncoderTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Encoder

  test "to_a2ui is an explicit not-implemented adapter stub" do
    surface = %Surface{
      id: :agent,
      app_id: :allbert,
      label: "Allbert Chat",
      path: "/agent",
      kind: :chat,
      status: :available,
      fallback_text: "Allbert chat is available at /agent."
    }

    assert {:error, :not_implemented} = Encoder.to_a2ui(surface)
  end
end
