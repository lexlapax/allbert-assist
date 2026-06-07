defmodule AllbertAssist.Actions.Intent.DirectAnswerTest do
  use ExUnit.Case, async: false
  @moduletag :db_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Resources.ImageMetadata
  alias AllbertAssist.Settings

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADElEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  defmodule FakeAnswerer do
    def answer(text, %{model_profile: profile}) do
      {:ok,
       %{
         message: "Model-backed answer for #{String.length(text)} characters.",
         diagnostic: %{status: :used, profile: profile.name}
       }}
    end
  end

  defmodule FailingAnswerer do
    def answer(_text, _context), do: {:error, :timeout}
  end

  defmodule MemoryAwareAnswerer do
    def answer(_text, %{active_memory: [%{body: body} | _rest], model_profile: profile}) do
      {:ok,
       %{
         message: "Memory-backed #{profile.name}: #{body}",
         diagnostic: %{status: :used, active_memory_count: 1}
       }}
    end
  end

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_memory_config = Application.get_env(:allbert_assist, Memory)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_direct_answer_config = Application.get_env(:allbert_assist, DirectAnswer)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-direct-answer-test-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Memory)
    Application.delete_env(:allbert_assist, Settings)

    on_exit(fn ->
      restore_home(original_home)
      restore_env(Paths, original_paths_config)
      restore_env(Memory, original_memory_config)
      restore_env(Settings, original_settings_config)
      restore_env(DirectAnswer, original_direct_answer_config)
      File.rm_rf!(home)
    end)

    :ok
  end

  test "disabled model path returns bounded side-effect-free fallback without echoing" do
    prompt = "What is Allbert?"

    assert {:ok, response} = DirectAnswer.run(%{text: prompt}, %{actor: "alice"})

    assert response.status == :completed
    assert response.message =~ "side-effect-free"
    assert response.message =~ "direct-answer model is disabled"
    refute response.message =~ "v0.26"
    refute response.message =~ prompt
    assert response.direct_answer.source == :bounded_fallback
    assert response.direct_answer[:model_enabled?] == false
  end

  test "enabled model path uses the configured answerer and redacted metadata" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: FakeAnswerer)

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, response} =
             DirectAnswer.run(%{text: "What is Allbert?"}, %{actor: "alice"})

    assert response.status == :completed
    assert response.message == "Model-backed answer for 16 characters."
    assert response.direct_answer.source == :model
    assert response.direct_answer.model_profile == "local"
    assert response.direct_answer.provider == "local_ollama"
    assert response.direct_answer.model_resolution.capability == "text_generation"
    refute inspect(response.direct_answer) =~ "What is Allbert?"
  end

  test "enabled model path resolves direct-answer preference fallback" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: FakeAnswerer)

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("model_preferences.tasks.direct_answer", ["fast", "local"], %{
               audit?: false
             })

    assert {:ok, response} =
             DirectAnswer.run(%{text: "What is Allbert?"}, %{actor: "alice"})

    assert response.direct_answer.source == :model
    assert response.direct_answer.model_profile == "local"

    assert Enum.any?(
             response.direct_answer.model_resolution.diagnostics,
             &match?(%{reason: {:provider_disabled, "fast", "openai"}}, &1)
           )
  end

  test "enabled model path receives bounded active memory context" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: MemoryAwareAnswerer)

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, entry} =
             Memory.upsert_system_entry(%{
               namespace: :identity,
               file_path: "persona.md",
               actor: "alice",
               summary: "Alice persona",
               body: "Reports should stay concise and direct."
             })

    assert {:ok, _reviewed} =
             Memory.review_entry(
               entry.path,
               %{
                 status: :kept,
                 reviewed_at: "2026-04-28T12:00:00Z",
                 reviewed_by: "alice"
               },
               user_id: "alice"
             )

    assert {:ok, response} =
             DirectAnswer.run(%{text: "How should reports be written?"}, %{
               actor: "alice",
               user_id: "alice",
               thread_id: "thr_direct_answer",
               request_started_at: "2026-05-28T12:00:00Z"
             })

    assert response.status == :completed
    assert response.message =~ "Reports should stay concise"
    assert response.direct_answer.source == :model
    assert response.direct_answer.active_memory.candidate_count_after_filter == 1

    assert [%{namespace: "identity"} = chunk] =
             response.direct_answer.active_memory.retrieved_chunks

    assert chunk.recency_decay == 0.5
    refute Map.has_key?(chunk, :body)
  end

  test "enabled vision path resolves vision_input and redacts image metadata" do
    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, _setting} = Settings.put("vision.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.vision_input", ["vision_fake"], %{
               audit?: false
             })

    image_path = write_png!("direct-answer-vision.png")

    assert {:ok, image_metadata} =
             ImageMetadata.from_path(image_path,
               resource_uri: "image://capture/img_direct_answer",
               filename: "direct-answer-vision.png",
               transient?: true
             )

    assert {:ok, response} =
             DirectAnswer.run(%{text: "What is in this image?"}, %{
               actor: "alice",
               request: %{metadata: %{image_inputs: [image_metadata]}}
             })

    assert response.status == :completed
    assert response.message =~ "Fixture vision answer for 1 image input"
    assert response.direct_answer.source == :model
    assert response.direct_answer.model_profile == "vision_fake"
    assert response.direct_answer.model_resolution.capability == "vision_input"

    assert [%{resource_uri: "image://capture/img_direct_answer"} = redacted] =
             response.direct_answer.media.image_inputs

    assert redacted.width == 1
    refute Map.has_key?(redacted, :path)
    refute inspect(response.direct_answer) =~ image_path
    refute File.exists?(image_path)
  end

  test "vision path falls back when vision is disabled" do
    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    image_path = write_png!("direct-answer-vision-disabled.png")

    assert {:ok, image_metadata} =
             ImageMetadata.from_path(image_path,
               resource_uri: "image://capture/img_disabled",
               transient?: true
             )

    assert {:ok, response} =
             DirectAnswer.run(%{text: "What is in this image?"}, %{
               actor: "alice",
               request: %{metadata: %{image_inputs: [image_metadata]}}
             })

    assert response.status == :completed
    assert response.direct_answer.source == :bounded_fallback
    assert response.direct_answer.reason == ":vision_disabled"
    refute File.exists?(image_path)
  end

  test "provider failures fall back without exposing the prompt" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: FailingAnswerer)

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, _setting} = Settings.put("providers.openai.enabled", true, %{audit?: false})

    assert {:ok, response} =
             DirectAnswer.run(%{text: "Should this call a provider?"}, %{actor: "alice"})

    assert response.status == :completed
    assert response.message =~ "configured direct-answer model was unavailable"
    assert response.direct_answer.source == :bounded_fallback
    assert response.direct_answer[:model_enabled?] == true
    refute response.message =~ "Should this call a provider?"
  end

  defp restore_home(nil), do: System.delete_env("ALLBERT_HOME")
  defp restore_home(value), do: System.put_env("ALLBERT_HOME", value)

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp write_png!(name) do
    path = Path.join([System.fetch_env!("ALLBERT_HOME"), "tmp", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, @png)
    path
  end
end
