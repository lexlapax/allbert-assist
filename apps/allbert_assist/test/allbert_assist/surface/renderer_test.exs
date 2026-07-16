defmodule AllbertAssist.Surface.RendererTest do
  use ExUnit.Case, async: true
  @moduletag :home_fs_serial

  alias AllbertAssist.Surface.Renderer

  test "renders the descriptor-selected surface payload without leaking model payload chrome" do
    assert {:ok, rendered} =
             Renderer.render_response(
               %{
                 message: "legacy message",
                 model_payload: "model clean",
                 surface_payload: "[surface] decorated"
               },
               %{payload: :surface_payload}
             )

    assert rendered.text == "[surface] decorated"
    refute rendered.text =~ "model clean"
  end

  test "chunks rendered text by byte size without splitting graphemes" do
    assert Renderer.chunks("ab🙂cd", 4) == ["ab", "🙂", "cd"]
  end

  test "appends redacted media outputs when the descriptor enables them" do
    assert {:ok, rendered} =
             Renderer.render_response(
               %{
                 message: "Image generated.",
                 media_outputs: [
                   %{
                     kind: :image,
                     source_action: "generate_image",
                     local_path: "/tmp/allbert-secret/image.png",
                     resource_uri: "file://[REDACTED_IMAGE_PATH]",
                     mime_type: "image/png"
                   }
                 ]
               },
               %{media_outputs: true}
             )

    assert rendered.text =~ "Image generated."
    assert rendered.text =~ "- image image/png file://[REDACTED_IMAGE_PATH] generate_image"
    refute rendered.text =~ "/tmp/allbert-secret"
  end

  test "renders approval handoff through descriptor primitives" do
    assert {:ok, rendered} =
             Renderer.render_response(
               %{
                 approval_handoff: %{
                   confirmation_id: "conf_surface",
                   summary: "Run the command?"
                 }
               },
               %{primitives: [:typed_command], threading: :reply_chain}
             )

    assert rendered.kind == :approval_handoff
    assert rendered.primitive == :typed_command
    assert rendered.text =~ "Reply with one exact command:"
    assert rendered.text =~ "ALLBERT:APPROVE:conf_surface"
  end

  test "supports TUI combined typed-command and list handoff text" do
    assert {:ok, rendered} =
             Renderer.render_response(
               %{
                 approval_handoff: %{
                   confirmation_id: "conf_tui",
                   status: :pending,
                   target_action: %{action: %{name: "write"}}
                 }
               },
               %{
                 primitives: [:typed_command, :list],
                 approval_text: :typed_and_list,
                 typed_intro: "Type one exact command:",
                 list_intro: "Approval options:"
               }
             )

    assert rendered.primitive == :typed_and_list
    assert rendered.text =~ "Type one exact command:"
    assert rendered.text =~ "Approval options:"
    assert rendered.text =~ "1. Approve - ALLBERT:APPROVE:conf_tui"
  end

  test "renders stream events and appends approval handoff when requested" do
    complete_event = %{
      type: :turn_complete,
      turn_id: "turn-surface",
      sequence: 1,
      model_payload: "model clean",
      surface_payload: "surface summary",
      metadata: %{status: :needs_confirmation}
    }

    assert {:ok, rendered} =
             Renderer.render_response(
               %{
                 turn_id: "turn-surface",
                 stream_events: [complete_event],
                 model_payload: "model clean",
                 surface_payload: "static surface",
                 approval_handoff: %{confirmation_id: "conf_stream"}
               },
               %{
                 payload: :surface_payload,
                 stream_events: true,
                 append_approval_handoff: true,
                 approval_text: :typed_and_list,
                 typed_intro: "Type one exact command:",
                 list_intro: "Approval options:"
               }
             )

    assert rendered.kind == :stream
    assert rendered.text =~ "surface summary"
    assert rendered.text =~ "ALLBERT:APPROVE:conf_stream"
    refute rendered.text =~ "model clean"
  end
end
