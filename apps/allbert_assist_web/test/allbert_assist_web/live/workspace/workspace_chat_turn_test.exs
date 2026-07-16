defmodule AllbertAssistWeb.WorkspaceChatTurnTest do
  use AllbertAssistWeb.ConnCase, async: false
  use AllbertAssistWeb.WorkspaceLiveCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias AllbertAssist.{Artifacts, Confirmations, Conversations, Repo, Settings}
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.ConversationMessageRef

  @runtime_async_timeout 60_000
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADElEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  test "mount renders redacted unified channel continuity for the active thread", %{conn: conn} do
    assert {:ok, thread} = Conversations.create_general_thread("local", "Continuity")
    assert {:ok, user_message} = Conversations.append_user_message(thread, "from slack")

    assert {:ok, assistant_message} =
             Conversations.append_assistant_message(thread, "token sk-live123")

    assert {:ok, _ref} =
             ChannelThread.record_message_ref(%{
               canonical_thread_id: thread.id,
               canonical_message_id: user_message.id,
               channel: "slack",
               receiver_account_ref: "slack:T0123",
               provider_message_id: "slack-user-1",
               direction: :in
             })

    assert {:ok, _ref} =
             ChannelThread.record_message_ref(%{
               canonical_thread_id: thread.id,
               canonical_message_id: assistant_message.id,
               channel: "email",
               receiver_account_ref: "email:mailbox:alice@example.com",
               provider_message_id: "<assistant@example.com>",
               direction: :out
             })

    {:ok, view, _html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    assert has_element?(view, "#workspace-unified-history[data-channel-count='2']")
    assert has_element?(view, "#workspace-unified-history [data-channel='slack']")
    assert has_element?(view, "#workspace-unified-history [data-channel='email']")

    panel = view |> element("#workspace-unified-history") |> render()
    assert panel =~ "token [REDACTED]"
    refute panel =~ "sk-live123"
  end

  test "mount binds workspace to a real conversation thread", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    assert String.starts_with?(thread_id, "thr_")
    assert {:ok, thread} = Conversations.get_thread("local", thread_id)
    assert thread.id == thread_id
  end

  test "mount treats nil thread query params as absent", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/workspace?thread_id=nil")
    thread_id = workspace_thread_id(view)

    assert String.starts_with?(thread_id, "thr_")
    assert {:ok, thread} = Conversations.get_thread("local", thread_id)
    assert thread.id == thread_id
    refute html =~ "Workspace thread fallback"
    refute html =~ ~s({:thread_not_found, "nil"})
  end

  test "chat pane renders persisted thread messages when available", %{conn: conn} do
    assert {:ok, thread} = Conversations.create_general_thread("local", "Analyze AAPL")

    assert {:ok, _message} =
             Conversations.append_user_message(thread, "analyze AAPL", %{channel: :live_view})

    assert {:ok, _message} =
             Conversations.append_assistant_message(thread, "Started the AAPL analysis.", %{
               channel: :live_view
             })

    {:ok, view, html} = live(conn, ~p"/workspace?thread_id=#{thread.id}&app_id=stocksage")

    assert workspace_thread_id(view) == thread.id
    assert html =~ "analyze AAPL"
    assert html =~ "Started the AAPL analysis."
    assert html =~ "Allbert"
    refute html =~ "Prompt draft"
  end

  test "mount treats empty and null thread query params as absent", %{conn: conn} do
    for query <- ["thread_id=", "thread_id=null"] do
      {:ok, view, html} = live(conn, "/workspace?#{query}")
      thread_id = workspace_thread_id(view)

      assert String.starts_with?(thread_id, "thr_")
      assert {:ok, thread} = Conversations.get_thread("local", thread_id)
      assert thread.id == thread_id
      refute html =~ "Workspace thread fallback"
      refute html =~ "workspace-thread-notice"
    end
  end

  test "mount recovers stale explicit thread query params quietly", %{conn: conn} do
    assert {:ok, recent_thread} =
             Conversations.create_general_thread("local", "Existing workspace thread")

    assert {:ok, _message} =
             Conversations.append_user_message(recent_thread, "do not reuse this thread", %{
               channel: :live_view
             })

    {:ok, view, html} = live(conn, ~p"/workspace?thread_id=thr_missing_manual")
    thread_id = workspace_thread_id(view)

    assert String.starts_with?(thread_id, "thr_")
    assert thread_id != "thr_missing_manual"
    assert thread_id != recent_thread.id
    assert {:ok, thread} = Conversations.get_thread("local", thread_id)
    assert thread.id == thread_id
    assert has_element?(view, "#workspace-thread-notice[role='status']")
    assert html =~ "Started a new workspace conversation"
    assert html =~ "thr_missing_manual"
    refute html =~ "do not reuse this thread"
    assert_patch(view, ~p"/workspace?thread_id=#{thread_id}")
    refute has_element?(view, "#agent-error")
    refute html =~ "Workspace thread fallback"
    refute html =~ ~s({:thread_not_found, "thr_missing_manual"})
  end

  test "submits prompts through the runtime boundary", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Say hello from the runtime boundary."})

    html = render_async(view, @runtime_async_timeout)

    assert_receive {:runtime_request, request}
    assert request.thread_id == thread_id
    assert request.session_id == live_view_session_id()
    assert request.active_app == :allbert
    assert String.starts_with?(request.provider_message_id, "live_view:in:")
    assert request.channel_thread_ref.channel == "live_view"
    assert request.channel_thread_ref.receiver_account_ref == "web:workspace"
    assert request.channel_thread_ref.provider_thread_ref["provider"] == "phoenix_live_view"
    assert request.channel_thread_ref.provider_thread_ref["surface"] == "live_view"
    assert request.metadata.local_surface == "live_view"

    assert [%ConversationMessageRef{direction: "in"}] =
             Repo.all(
               from(ref in ConversationMessageRef,
                 where:
                   ref.channel == "live_view" and
                     ref.provider_message_id == ^request.provider_message_id
               )
             )

    assert %Event{channel: "live_view", status: "processed", user_id: "local"} =
             Repo.get_by(Event,
               channel: "live_view",
               external_event_id: request.provider_message_id
             )

    assert has_element?(view, "#agent-response")
    assert html =~ "Runtime LiveView response: Say hello from the runtime boundary."
    assert has_element?(view, "#agent-status")
    assert html =~ "completed"
    assert has_element?(view, "#agent-signal")
  end

  test "resolves LiveView identity through the identity map before runtime submit", %{
    conn: conn
  } do
    conn =
      Plug.Test.init_test_session(conn, %{
        "live_view_external_user_id" => "browser-op",
        "live_view_identity_map" => [
          %{"external_user_id" => "browser-op", "user_id" => "mapped-web-user"}
        ]
      })

    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Say hello with mapped identity."})

    _html = render_async(view, @runtime_async_timeout)

    assert_receive {:runtime_request, request}
    assert request.user_id == "mapped-web-user"
    assert request.operator_id == "mapped-web-user"
    assert request.session_id == live_view_session_id("browser-op")
    assert request.metadata.local_surface == "live_view"
  end

  test "renders generated image and audio outputs in the chat timeline", %{
    conn: conn,
    root: root
  } do
    image_path = Path.join([root, "tmp", "generated-images", "chat", "image.png"])
    audio_path = Path.join([root, "tmp", "voice-synthesis", "chat", "voice.wav"])
    File.mkdir_p!(Path.dirname(image_path))
    File.mkdir_p!(Path.dirname(audio_path))
    File.write!(image_path, @png)
    File.write!(audio_path, <<"RIFF", "workspace audio">>)

    thread = create_workspace_thread("Generated media chat")

    assert {:ok, message} =
             Conversations.append_assistant_message(thread, "Generated media outputs.", %{
               metadata: %{
                 media_outputs: [
                   %{
                     kind: :image,
                     source_action: "generate_image",
                     local_path: image_path,
                     mime_type: "image/png",
                     filename: "image.png"
                   },
                   %{
                     kind: :audio,
                     source_action: "synthesize_voice",
                     local_path: audio_path,
                     mime_type: "audio/wav",
                     filename: "voice.wav"
                   }
                 ]
               }
             })

    {:ok, view, html} = live(conn, ~p"/workspace?thread_id=#{thread.id}")

    assert has_element?(
             view,
             ~s(img.workspace-media-output-image[src="/workspace/media/#{message.id}/0"])
           )

    assert has_element?(
             view,
             ~s(audio.workspace-media-output-audio[src="/workspace/media/#{message.id}/1"])
           )

    assert html =~ "image · image/png · generate_image"
    assert html =~ "audio · audio/wav · synthesize_voice"
    refute html =~ image_path
    refute html =~ audio_path
  end

  test "workspace microphone capture denial writes no audio resource", %{conn: conn, root: root} do
    enable_workspace_voice!()

    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element("#voice-capture-request")
    |> render_click()

    assert has_element?(view, "#approval-handoff")
    [pending] = Confirmations.list(status: :pending)
    assert pending["target_action"]["name"] == "capture_workspace_voice"
    assert pending["target_permission"] == "microphone_capture"
    assert pending["params_summary"]["resource_uri"] =~ "mic://capture/"

    view
    |> element("#approval-deny")
    |> render_click()

    assert {:ok, denied} = Confirmations.read(pending["id"])
    assert denied["status"] == "denied"
    refute has_element?(view, "#voice-capture-form")
    refute File.exists?(Path.join(root, "audio"))
    refute File.exists?(Path.join([root, "tmp", "voice-captures"]))
  end

  test "approved workspace microphone upload transcribes into runtime text", %{
    conn: conn,
    root: root
  } do
    enable_workspace_voice!()

    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    view
    |> element("#voice-capture-request")
    |> render_click()

    [pending] = Confirmations.list(status: :pending)
    capture_id = pending["resume_params_ref"]["capture_id"]
    resource_uri = pending["params_summary"]["resource_uri"]

    view
    |> element("#approval-approve")
    |> render_click()

    assert {:ok, approved} = Confirmations.read(pending["id"])
    assert approved["status"] == "approved"
    assert has_element?(view, "#voice-capture-form[data-capture-resource='#{resource_uri}']")

    upload =
      file_input(view, "#voice-capture-form", :voice_capture, [
        %{
          name: "hello.wav",
          content: File.read!(fixture_path("hello.wav")),
          type: "audio/wav"
        }
      ])

    render_upload(upload, "hello.wav")

    view
    |> form("#voice-capture-form", %{})
    |> render_submit()

    _html = render_async(view, @runtime_async_timeout)

    assert_receive {:runtime_request,
                    %{
                      text: "hello from fixture audio",
                      thread_id: ^thread_id,
                      metadata: %{voice: voice_metadata}
                    }}

    assert voice_metadata.resource_uri == resource_uri
    assert voice_metadata.provider_profile == "voice_stt_fake"
    assert voice_metadata.audio_format == "wav"
    refute inspect(voice_metadata) =~ fixture_path("hello.wav")
    refute File.exists?(Path.join([root, "tmp", "voice-captures", capture_id]))
  end

  test "retained workspace microphone upload stores audio through Artifacts Central", %{
    conn: conn,
    root: root
  } do
    enable_workspace_voice!()
    enable_workspace_artifacts!()
    assert {:ok, _setting} = Settings.put("voice.audio.retention_enabled", true, %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/workspace")

    view
    |> element("#voice-capture-request")
    |> render_click()

    [pending] = Confirmations.list(status: :pending)
    capture_id = pending["resume_params_ref"]["capture_id"]
    resource_uri = pending["params_summary"]["resource_uri"]

    view
    |> element("#approval-approve")
    |> render_click()

    assert {:ok, approved} = Confirmations.read(pending["id"])
    assert approved["status"] == "approved"
    assert has_element?(view, "#voice-capture-form[data-capture-resource='#{resource_uri}']")

    upload =
      file_input(view, "#voice-capture-form", :voice_capture, [
        %{
          name: "hello.wav",
          content: File.read!(fixture_path("hello.wav")),
          type: "audio/wav"
        }
      ])

    render_upload(upload, "hello.wav")

    view
    |> form("#voice-capture-form", %{})
    |> render_submit()

    _html = render_async(view, @runtime_async_timeout)

    assert_receive {:runtime_request, %{metadata: %{voice: voice_metadata}}}
    assert voice_metadata.audio_format == "wav"

    assert {:ok, artifacts} = Artifacts.list(origin: "retained_voice_audio")
    assert [%{metadata: metadata}] = artifacts
    assert metadata.mime == "audio/wav"
    assert metadata.source_resource_uri =~ "mic://capture/"
    assert metadata.provenance["media_retention"]["kind"] == "voice_audio"

    refute File.exists?(Path.join([root, "audio", capture_id]))
    refute File.exists?(Path.join([root, "tmp", "voice-captures", capture_id]))
  end

  test "workspace image upload attaches bounded image metadata to runtime prompt", %{
    conn: conn,
    root: root
  } do
    enable_workspace_vision!()

    {:ok, view, _html} = live(conn, ~p"/workspace")
    thread_id = workspace_thread_id(view)

    upload =
      file_input(view, "#agent-form", :image_input, [
        %{
          name: "frame.png",
          content: @png,
          type: "image/png"
        }
      ])

    render_upload(upload, "frame.png")

    assert has_element?(view, "#image-input-uploads")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Describe the image"})

    _html = render_async(view, @runtime_async_timeout)

    assert_receive {:runtime_request,
                    %{
                      text: "Describe the image",
                      thread_id: ^thread_id,
                      metadata: %{image_inputs: [image_metadata]}
                    }}

    assert image_metadata.resource_uri =~ "image://capture/img_"
    assert image_metadata.path =~ Path.join([root, "tmp", "image-inputs"])
    assert image_metadata.image_format == "png"
    assert image_metadata.mime_type == "image/png"
    assert image_metadata.width == 1
    assert image_metadata.height == 1
    assert image_metadata.pixel_count == 1
    assert image_metadata.byte_size == byte_size(@png)
    assert byte_size(image_metadata.content_sha256) == 64
    assert image_metadata.redaction_status == "metadata_only"
    assert image_metadata.transient?
    refute inspect(image_metadata) =~ inspect(@png)
  end

  test "retained workspace image upload stores image input through Artifacts Central", %{
    conn: conn,
    root: root
  } do
    enable_workspace_vision!()
    enable_workspace_artifacts!()

    assert {:ok, _setting} =
             Settings.put("vision.media.retention_enabled", true, %{audit?: false})

    {:ok, view, _html} = live(conn, ~p"/workspace")

    upload =
      file_input(view, "#agent-form", :image_input, [
        %{
          name: "frame.png",
          content: @png,
          type: "image/png"
        }
      ])

    render_upload(upload, "frame.png")

    view
    |> element("#agent-form")
    |> render_submit(%{"prompt" => "Describe retained image"})

    _html = render_async(view, @runtime_async_timeout)

    assert_receive {:runtime_request,
                    %{
                      metadata: %{image_inputs: [image_metadata]}
                    }}

    assert image_metadata.resource_uri =~ "image://capture/img_"
    assert image_metadata.path =~ Path.join([root, "artifacts", "objects"])
    refute image_metadata.path =~ Path.join(root, "images")
    refute image_metadata.transient?

    assert {:ok, artifacts} = Artifacts.list(origin: "retained_vision_media")
    assert [%{metadata: metadata}] = artifacts
    assert metadata.mime == "image/png"
    assert metadata.source_resource_uri == image_metadata.resource_uri
    assert metadata.provenance["media_retention"]["kind"] == "vision_media"
  end

  defp enable_workspace_voice! do
    assert {:ok, _resolved} = Settings.put("voice.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.speech_to_text", ["voice_stt_fake"], %{
               audit?: false
             })
  end

  defp enable_workspace_vision! do
    assert {:ok, _resolved} = Settings.put("vision.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.vision_input", ["vision_fake"], %{
               audit?: false
             })
  end

  defp enable_workspace_artifacts! do
    assert {:ok, _setting} = Settings.put("artifacts.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("artifacts.retention_enabled", true, %{audit?: false})
  end

  defp fixture_path(name) do
    Path.expand("../../../../../allbert_assist/test/fixtures/v0.48/audio/#{name}", __DIR__)
  end
end
