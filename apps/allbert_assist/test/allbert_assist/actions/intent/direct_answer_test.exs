defmodule AllbertAssist.Actions.Intent.DirectAnswerTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Intent.DirectAnswer
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

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_direct_answer_config = Application.get_env(:allbert_assist, DirectAnswer)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-direct-answer-test-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    on_exit(fn ->
      restore_home(original_home)
      restore_env(Paths, original_paths_config)
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
