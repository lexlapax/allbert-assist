defmodule AllbertAssist.Actions.Intent.DirectAnswerTest do
  use ExUnit.Case, async: false
  @moduletag :db_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Projection
  alias AllbertAssist.Models.FallbackAudit
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

  defmodule ScriptedAnswerer do
    def answer(_text, %{model_profile: profile}) do
      send(self(), {:provider_called, profile.name})

      case Process.get({__MODULE__, profile.name}, {:error, :timeout}) do
        {:ok, message} -> {:ok, %{message: message, diagnostic: %{status: :used}}}
        {:error, reason} -> {:error, reason}
      end
    end
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

  defmodule BudgetAnswerer do
    def answer(_text, %{active_memory: chunks}) do
      send(self(), {:active_memory_prompt, chunks})
      {:ok, %{message: "Bounded memory prompt", diagnostic: %{status: :used}}}
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

    {:ok, projection} =
      Projection.start_link(root: Paths.memory_projection_root(), name: nil)

    on_exit(fn ->
      if Process.alive?(projection), do: GenServer.stop(projection)
      restore_home(original_home)
      restore_env(Paths, original_paths_config)
      restore_env(Memory, original_memory_config)
      restore_env(Settings, original_settings_config)
      restore_env(DirectAnswer, original_direct_answer_config)
      File.rm_rf!(home)
    end)

    {:ok, projection: projection}
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

  test "disabled model path tolerates malformed image input list tails" do
    assert {:ok, response} =
             DirectAnswer.run(%{text: "What is this?"}, %{
               actor: "alice",
               request: %{
                 metadata: %{
                   image_inputs: [%{api_key: "secret-value", resource_uri: "image://one"} | :tail]
                 }
               }
             })

    assert response.status == :completed
    assert response.direct_answer.source == :bounded_fallback
    refute inspect(response) =~ "secret-value"
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

  test "enabled model path resolves direct-answer preferences local-first" do
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

    assert response.direct_answer.model_resolution.diagnostics == []
  end

  test "enabled model path receives bounded active memory context", %{projection: projection} do
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

    assert {:ok, _build} = Projection.rebuild(projection)

    assert {:ok, response} =
             DirectAnswer.run(%{text: "How should reports be written?"}, %{
               actor: "alice",
               user_id: "alice",
               thread_id: "thr_direct_answer",
               request_started_at: "2026-05-28T12:00:00Z",
               memory_projection: projection
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

  test "text insertion enforces the shared 8000-byte Active Memory ceiling", %{
    projection: projection
  } do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: BudgetAnswerer)

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    for index <- 1..5 do
      body = "budget #{index} " <> String.duplicate("x", 1_991)
      assert byte_size(body) == 2_000
      assert {:ok, entry} = append_kept("alice", body)
      assert entry.review_status == :kept
    end

    assert {:ok, _build} = Projection.rebuild(projection)

    assert {:ok, response} =
             DirectAnswer.run(%{text: "Use the budget memory"}, %{
               actor: "alice",
               user_id: "alice",
               request_started_at: "2026-07-29T12:00:00Z",
               memory_projection: projection
             })

    assert_receive {:active_memory_prompt, chunks}
    assert Enum.sum(Enum.map(chunks, &byte_size(&1.body))) == 8_000
    assert response.direct_answer.active_memory.prompt_budget_bytes == 8_000
    assert response.direct_answer.active_memory.prompt_bytes == 8_000
    assert response.direct_answer.active_memory.prompt_truncated?
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

  test "runtime fallback is default off and makes exactly one provider call" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    enable_text_chain!()

    assert {:ok, response} = DirectAnswer.run(%{text: "answer"}, %{actor: "alice"})

    assert response.message =~ "configured direct-answer model was unavailable"
    assert_receive {:provider_called, "local"}
    refute_receive {:provider_called, "fast"}
    refute Map.has_key?(response.direct_answer, :fallback)
  end

  test "local to hosted fallback is denied without the second acknowledgement" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    enable_text_chain!()
    put_setting!("models.fallback.enabled", true)
    Process.put({ScriptedAnswerer, "fast"}, {:ok, "hosted answer"})

    assert {:ok, response} = DirectAnswer.run(%{text: "answer"}, %{actor: "alice"})

    assert response.message == "The configured model chain failed: local."
    assert response.direct_answer.fallback.classification == :ambiguous
    assert response.direct_answer.fallback.provider_call_count == 1
    assert_receive {:provider_called, "local"}
    refute_receive {:provider_called, "fast"}
    assert File.read!(FallbackAudit.audit_path()) =~ "model_fallback.egress_denied"
  end

  test "opted-in fallback names the non-primary answering profile and audits it" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    enable_text_chain!()
    put_setting!("models.fallback.enabled", true)
    put_setting!("models.fallback.allow_local_to_hosted", true)
    Process.put({ScriptedAnswerer, "fast"}, {:ok, "hosted answer"})

    assert {:ok, response} = DirectAnswer.run(%{text: "answer"}, %{actor: "alice"})

    assert response.message == "hosted answer"
    assert response.direct_answer.model_profile == "fast"
    assert response.direct_answer.fallback.failed_profile == "local"
    assert response.direct_answer.fallback.answered_profile == "fast"
    assert response.direct_answer.fallback.provider_call_count == 2
    assert_receive {:provider_called, "local"}
    assert_receive {:provider_called, "fast"}

    audit = File.read!(FallbackAudit.audit_path())
    assert audit =~ "model_fallback.answered"
    assert audit =~ "failed_profile: local"
    assert audit =~ "answered_profile: fast"
  end

  test "unknown partial failures never retry" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    enable_text_chain!()
    put_setting!("models.fallback.enabled", true)
    put_setting!("models.fallback.allow_local_to_hosted", true)
    Process.put({ScriptedAnswerer, "local"}, {:error, {:unknown_stream_state, :closed}})
    Process.put({ScriptedAnswerer, "fast"}, {:ok, "must not appear"})

    assert {:ok, response} = DirectAnswer.run(%{text: "answer"}, %{actor: "alice"})

    assert response.direct_answer.fallback.classification == :partial
    assert response.direct_answer.fallback.provider_call_count == 1
    assert_receive {:provider_called, "local"}
    refute_receive {:provider_called, "fast"}
  end

  test "fallback stops after one failover even when the setting permits two" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScriptedAnswerer)
    enable_text_chain!(["local", "fast", "anthropic_fast"])
    put_setting!("providers.anthropic.enabled", true)
    put_setting!("models.fallback.enabled", true)
    put_setting!("models.fallback.allow_local_to_hosted", true)
    put_setting!("models.fallback.max_failovers_per_turn", 2)

    assert {:ok, response} = DirectAnswer.run(%{text: "answer"}, %{actor: "alice"})

    assert response.message == "The configured model chain failed: local → fast."
    assert response.direct_answer.fallback.provider_call_count == 2
    assert_receive {:provider_called, "local"}
    assert_receive {:provider_called, "fast"}
    refute_receive {:provider_called, "anthropic_fast"}
  end

  defp append_kept(actor, body) do
    with {:ok, entry} <-
           Memory.append(%{
             category: :notes,
             body: body,
             actor: actor,
             agent: "direct-answer-test",
             channel: :test,
             source_signal_id: "budget"
           }) do
      Memory.review_entry(
        entry.path,
        %{status: :kept, reviewed_by: actor, reviewed_at: "2026-07-29T10:00:00Z"},
        user_id: actor
      )
    end
  end

  defp enable_text_chain!(profiles \\ ["local", "fast"]) do
    put_setting!("intent.direct_answer_model_enabled", true)
    put_setting!("providers.openai.enabled", true)
    put_setting!("model_preferences.tasks.direct_answer", profiles)
  end

  defp put_setting!(key, value) do
    assert {:ok, _setting} = Settings.put(key, value, %{audit?: false})
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
