defmodule AllbertAssist.Actions.Intent.DirectAnswerTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

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

    assert {:ok, _setting} = Settings.put("providers.openai.enabled", true, %{audit?: false})

    assert {:ok, response} =
             DirectAnswer.run(%{text: "What is Allbert?"}, %{actor: "alice"})

    assert response.status == :completed
    assert response.message == "Model-backed answer for 16 characters."
    assert response.direct_answer.source == :model
    assert response.direct_answer.model_profile == "fast"
    assert response.direct_answer.provider == "openai"
    refute inspect(response.direct_answer) =~ "What is Allbert?"
  end

  test "enabled model path receives bounded active memory context" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: MemoryAwareAnswerer)

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, _setting} = Settings.put("providers.openai.enabled", true, %{audit?: false})

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
                 reviewed_at: "2026-05-28T12:00:00Z",
                 reviewed_by: "alice"
               },
               user_id: "alice"
             )

    assert {:ok, response} =
             DirectAnswer.run(%{text: "How should reports be written?"}, %{
               actor: "alice",
               user_id: "alice",
               thread_id: "thr_direct_answer"
             })

    assert response.status == :completed
    assert response.message =~ "Reports should stay concise"
    assert response.direct_answer.source == :model
    assert response.direct_answer.active_memory.candidate_count_after_filter == 1

    assert [%{namespace: "identity"} = chunk] =
             response.direct_answer.active_memory.retrieved_chunks

    refute Map.has_key?(chunk, :body)
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
end
