defmodule AllbertAssist.Security.V049VisionModalityEvalTest do
  use AllbertAssist.DataCase, async: false, lane: :security_eval_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Runtime.Trace
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Models
  alias AllbertAssist.Settings.Secrets
  alias AllbertBrowser.Actions.AnalyzeScreenshot
  alias AllbertBrowser.Cache, as: BrowserCache
  alias Jido.Signal

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADElEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  @eval_ids [
    "vision-media-size-bound-001",
    "vision-binary-trace-redaction-001",
    "vision-provider-capability-check-001",
    "vision-operator-supplied-only-no-autocapture-001",
    "vision-browser-screenshot-analysis-001",
    "image-generation-floor-confirmation-001",
    "image-generation-cost-display-only-001",
    "media-render-no-generated-ui-code-001"
  ]

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_direct_answer_config = Application.get_env(:allbert_assist, DirectAnswer)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Confirmations)
    Application.delete_env(:allbert_assist, DirectAnswer)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-v049-vision-eval-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Confirmations, original_confirmations_config)
      restore_app_env(DirectAnswer, original_direct_answer_config)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
    end)

    {:ok, home: home, context: context()}
  end

  test "v0.49 eval inventory rows are complete" do
    rows = EvalInventory.rows_for_milestone(:v049)

    assert Enum.map(rows, & &1.id) == @eval_ids
    assert Enum.all?(rows, &(&1.surface == :vision_modality))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
  end

  test "vision input is bounded, redacted, and capability-checked", %{home: home} do
    assert_eval!("vision-media-size-bound-001")
    assert_eval!("vision-binary-trace-redaction-001")
    assert_eval!("vision-provider-capability-check-001")

    enable_direct_answer_model!()
    enable_vision!()

    assert {:ok, _setting} =
             Settings.put("vision.media.max_bytes", 8, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.capabilities.vision_input",
               ["image_fake", "vision_fake"],
               %{audit?: false}
             )

    assert {:ok, resolution} = Models.for(:vision_input)
    assert resolution.profile.name == "vision_fake"

    assert Enum.any?(
             resolution.diagnostics,
             &match?(
               %{reason: {:profile_missing_capability, "image_fake", "vision_input"}},
               &1
             )
           )

    image_path = write_png!(home, "oversized.png")

    assert {:ok, response} =
             DirectAnswer.run(%{text: "What is in this image?"}, %{
               actor: "operator",
               request: %{
                 metadata: %{
                   image_inputs: [
                     %{
                       path: image_path,
                       resource_uri: "image://capture/img_v049_oversized",
                       filename: "oversized.png",
                       transient?: true
                     }
                   ]
                 }
               }
             })

    assert response.status == :completed
    assert response.direct_answer.source == :bounded_fallback
    assert response.direct_answer.reason =~ "image_input_too_large"
    refute File.exists?(image_path)

    trace =
      %{
        image_inputs: [
          %{
            resource_uri: "image://capture/img_v049_trace",
            path: Path.join(home, "private-frame.png"),
            raw_image: @png,
            byte_size: byte_size(@png),
            width: 1,
            height: 1,
            mime_type: "image/png"
          }
        ]
      }
      |> turn("Trace v0.49 image metadata")
      |> Trace.text()

    assert trace =~ "image://capture/img_v049_trace"
    assert trace =~ "image_inputs"
    refute trace =~ home
    refute trace =~ "raw_image"
    refute trace =~ Base.encode64(@png)
  end

  test "screen resource identity is inert and does not imply autonomous capture" do
    assert_eval!("vision-operator-supplied-only-no-autocapture-001")

    assert {:ok, resource_uri} = ResourceURI.screen_capture("screen_v049")
    assert resource_uri == "screen://capture/screen_v049"

    assert {:ok, fields} = ResourceURI.derived_fields(resource_uri)
    assert fields.origin_kind == :image_input
    assert fields.media_kind == :screen
    assert fields.capture_id == "screen_v049"

    assert {:ok, ^resource_uri} =
             ResourceURI.scope_uri(:image_input, :image_input, resource_uri, nil)

    refute "capture_screen" in ActionsRegistry.names()
    refute "screen_capture" in ActionsRegistry.names()
    refute "take_screenshot" in ActionsRegistry.names()
  end

  test "browser screenshot refs bridge into vision without new capture authority", %{
    context: context
  } do
    assert_eval!("vision-browser-screenshot-analysis-001")

    enable_direct_answer_model!()
    enable_vision!()

    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.vision_input", ["vision_fake"], %{
               audit?: false
             })

    assert {:ok, artifact} =
             BrowserCache.put("session_v049", "screenshot", @png,
               ext: ".png",
               metadata: %{redacted_credential_inputs?: true}
             )

    assert {:ok, response} =
             AnalyzeScreenshot.run(
               %{screenshot_ref: artifact.ref, text: "Analyze this browser screenshot"},
               context
             )

    assert response.status == :completed
    assert response.message =~ "Fixture vision answer for 1 image input"
    assert response.browser_screenshot.screenshot_ref == artifact.ref

    assert [
             %{
               resource_uri: "screen://capture/browser_" <> _hash,
               source: :browser_screenshot,
               origin_kind: :browser_screenshot,
               screenshot_ref: screenshot_ref,
               redacted_credential_inputs?: true
             }
           ] = response.direct_answer.media.image_inputs

    assert screenshot_ref == artifact.ref
    refute inspect(response) =~ artifact.path
    refute "capture_screen" in ActionsRegistry.names()
    refute "screen_capture" in ActionsRegistry.names()
    refute "take_screenshot" in ActionsRegistry.names()
  end

  test "image generation confirms remote providers and keeps cost metadata display-only", %{
    context: context
  } do
    assert_eval!("image-generation-floor-confirmation-001")
    assert_eval!("image-generation-cost-display-only-001")

    enable_image!()
    use_openai_image!()

    assert {:ok, pending} =
             Runner.run("generate_image", %{prompt: "remote image confirmation"}, context)

    assert pending.status == :needs_confirmation
    assert pending.confirmation_id
    assert pending.permission_decision.decision == :needs_confirmation
    assert pending.image_metadata.provider_profile == "image_openai"

    use_fake_image!()

    assert {:ok, response} =
             Runner.run("generate_image", %{prompt: "fixture image usage metadata"}, context)

    assert response.status == :completed
    assert response.permission_decision.decision == :allowed
    assert response.image_metadata.usage == %{source: :fixture}
    assert response.image_metadata.cost == %{source: :unavailable}
    refute Map.has_key?(response.image_metadata, :budget)
    refute Map.has_key?(response.image_metadata, :remaining_budget)
  end

  test "generated media output does not create executable workspace UI code", %{context: context} do
    assert_eval!("media-render-no-generated-ui-code-001")

    enable_image!()
    use_fake_image!()

    prompt = "draw this safely: <script>alert('x')</script> javascript:alert(1)"

    assert {:ok, response} = Runner.run("generate_image", %{prompt: prompt}, context)

    assert response.status == :completed
    assert response.image_file
    assert response.output_resource_uri == "file://[REDACTED_IMAGE_PATH]"

    refute Map.has_key?(response, :emitted_fragments)
    refute Map.has_key?(response, :workspace)
    refute Enum.any?(response.actions, &Map.has_key?(&1, :surface))
    refute inspect(response.actions) =~ "<script>"
    refute inspect(response.actions) =~ "javascript:"
    refute inspect(response.image_metadata) =~ "<script>"
    refute inspect(response.image_metadata) =~ "javascript:"
  end

  defp assert_eval!(id), do: EvalInventory.row!(id)

  defp enable_direct_answer_model! do
    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})
  end

  defp enable_vision! do
    assert {:ok, _setting} = Settings.put("vision.enabled", true, %{audit?: false})
  end

  defp enable_image! do
    assert {:ok, _setting} = Settings.put("image.enabled", true, %{audit?: false})
  end

  defp use_fake_image! do
    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.image_generation", ["image_fake"], %{
               audit?: false
             })
  end

  defp use_openai_image! do
    assert {:ok, _provider} = Settings.put("providers.openai.enabled", true, %{audit?: false})

    assert {:ok, _secret} =
             Secrets.put_secret("secret://providers/openai/api_key", "sk-test-openai", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.image_generation", ["image_openai"], %{
               audit?: false
             })
  end

  defp context do
    %{
      actor: "operator",
      user_id: "operator",
      channel: :test,
      surface: "v049_eval",
      request: %{operator_id: "operator", channel: :test}
    }
  end

  defp write_png!(home, filename) do
    path = Path.join([home, "tmp", filename])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, @png)
    path
  end

  defp turn(metadata, text) do
    {:ok, input_signal} =
      Signal.new(
        "allbert.input.received",
        %{text: text},
        source: "/allbert/channels/test",
        subject: "user-v049-vision-eval"
      )

    {:ok, response_signal} =
      Signal.new(
        "allbert.agent.responded",
        %{message: "Runtime response: #{text}"},
        source: "/allbert/runtime",
        subject: "user-v049-vision-eval"
      )

    %{
      input_signal: input_signal,
      response_signal: response_signal,
      request: %{
        text: text,
        channel: :test,
        operator_id: "user-v049-vision-eval",
        user_id: "user-v049-vision-eval",
        thread_id: "thread-v049-vision-eval",
        session_id: nil,
        metadata: metadata
      },
      response: %{
        message: "Runtime response: #{text}",
        status: :completed,
        actions: [],
        diagnostics: []
      },
      workspace: %{
        canvas_tiles: [],
        ephemeral_surfaces: [],
        emitted_fragments: [],
        dropped_fragments: []
      },
      agent: AllbertAssist.Agents.IntentAgent
    }
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
