defmodule AllbertAssist.Surface.RendererTest do
  use ExUnit.Case, async: true
  @moduletag :home_fs_serial

  alias AllbertAssist.PublicProtocol.Acp.Mapping, as: AcpMapping
  alias AllbertAssist.PublicProtocol.OpenAI.Mapping, as: OpenAIMapping
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Surface.Renderer

  test "canonical action responses retain each frozen surface payload preference" do
    response =
      Response.canonical_action_result(
        {:ok,
         %{
           message: "channel and public-protocol text",
           model_payload: "model-only text",
           surface_payload: "CLI and TUI text",
           status: :completed,
           custom_edge: %{preserved: true}
         }},
        "compatibility_probe"
      )

    for {payload, expected} <- [
          message: "channel and public-protocol text",
          model_payload: "model-only text",
          surface_payload: "CLI and TUI text"
        ] do
      assert {:ok, %{kind: :text, text: ^expected, chunks: [^expected]}} =
               Renderer.render_response(response, %{payload: payload})
    end

    assert response.custom_edge == %{preserved: true}
  end

  test "canonical action responses retain frozen public-protocol terminal mapping" do
    completed = canonical_public_response(:completed)

    assert {:ok, completion} =
             OpenAIMapping.chat_completion(
               completed,
               %{model: "local"},
               %{client_id: "fixture-client"}
             )

    assert get_in(completion, ["choices", Access.at(0), "message", "content"]) ==
             "public message"

    assert {:ok, [update, terminal]} =
             AcpMapping.prompt_outbound(
               completed,
               %{id: "acp_session_fixture", client_id: "fixture-client"},
               41
             )

    assert get_in(update, ["params", "update", "content", "text"]) == "public message"

    assert terminal == %{
             "jsonrpc" => "2.0",
             "id" => 41,
             "result" => %{"stopReason" => "end_turn"}
           }

    for status <-
          Response.action_statuses() --
            [
              :needs_confirmation,
              :denied,
              :rejected,
              :error,
              :failed,
              :unsupported,
              :unavailable
            ] do
      response = canonical_public_response(status)

      assert {:ok, _completion} =
               OpenAIMapping.chat_completion(
                 response,
                 %{model: "local"},
                 %{client_id: "fixture-client"}
               )

      assert {:ok, [_update, _terminal]} =
               AcpMapping.prompt_outbound(
                 response,
                 %{id: "acp_session_fixture", client_id: "fixture-client"},
                 41
               )
    end

    for {status, openai_status, openai_code, acp_code} <- [
          {:denied, 403, "authorization_error", "authorization_error"},
          {:error, 400, "runtime_error", "runtime_error"},
          {:failed, 400, "runtime_error", "runtime_error"},
          {:unsupported, 400, "runtime_error", "runtime_error"},
          {:unavailable, 400, "runtime_error", "runtime_error"}
        ] do
      response = canonical_public_response(status)

      assert {:error, openai_error} =
               OpenAIMapping.chat_completion(
                 response,
                 %{model: "local"},
                 %{client_id: "fixture-client"}
               )

      assert openai_error.status == openai_status
      assert openai_error.code == openai_code
      assert openai_error.message == "#{status} edge"

      assert {:error, acp_error} =
               AcpMapping.prompt_outbound(
                 response,
                 %{id: "acp_session_fixture", client_id: "fixture-client"},
                 42
               )

      assert acp_error.code == -32_000
      assert acp_error.data == %{"code" => acp_code}
      assert acp_error.message == "#{status} edge"
    end
  end

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

  defp canonical_public_response(status) do
    Response.canonical_action_result(
      {:ok,
       %{
         message: if(status == :completed, do: "public message", else: "#{status} edge"),
         model_payload: "model-only payload",
         surface_payload: "surface-only payload",
         status: status
       }},
      "compatibility_probe"
    )
  end
end
