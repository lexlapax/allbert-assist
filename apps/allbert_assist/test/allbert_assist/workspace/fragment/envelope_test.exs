defmodule AllbertAssist.Workspace.Fragment.EnvelopeTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Fragment.Envelope

  test "signs and verifies a valid envelope" do
    assert {:ok, envelope} = Envelope.sign(valid_attrs(), "0123456789abcdef")

    assert is_binary(envelope.signature)
    assert :ok = Envelope.verify(envelope, "0123456789abcdef")
    assert {:error, :signature_invalid} = Envelope.verify(envelope, "different-secret")
  end

  test "rejects invalid envelope shape" do
    assert {:error, :invalid_scope} =
             Envelope.sign(Map.put(valid_attrs(), :scope, :global), "0123456789abcdef")

    assert {:error, :invalid_surface} =
             Envelope.sign(
               Map.put(valid_attrs(), :surface, %{component: :text}),
               "0123456789abcdef"
             )
  end

  defp valid_attrs do
    %{
      surface: %Surface{
        id: :fragment,
        app_id: :allbert,
        label: "Fragment",
        path: "/workspace",
        kind: :canvas,
        status: :available,
        nodes: [%Node{id: "fragment-text", component: :text, props: %{text: "hello"}}],
        fallback_text: "Fragment fallback"
      },
      emitter_id: "AllbertAssist.Actions.Intent.DirectAnswer",
      user_id: "local",
      thread_id: "thread-1",
      scope: :canvas,
      kind: :text,
      emitted_at: ~U[2026-05-18 00:00:00Z]
    }
  end
end
