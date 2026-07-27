defmodule AllbertAssist.FirstRun.FlagshipCoreTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Store

  defmodule Answerer do
    def answer(_text, %{model_profile: profile}) do
      {:ok, %{message: "first model answer", diagnostic: %{profile: profile.name}}}
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-flagship-core-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    settings_env = Application.get_env(:allbert_assist, Settings)
    paths_env = Application.get_env(:allbert_assist, Paths)
    answer_env = Application.get_env(:allbert_assist, DirectAnswer)
    Application.put_env(:allbert_assist, Settings, root: root)
    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, DirectAnswer, answerer: Answerer)

    on_exit(fn ->
      restore(Settings, settings_env)
      restore(Paths, paths_env)
      restore(DirectAnswer, answer_env)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "fresh Home with a usable local profile answers the first question with zero clicks" do
    local = %{
      profile: "local",
      provider: "local_ollama",
      provider_class: :local,
      verification: :doctor_healthy
    }

    assert {:ok, %{state: :auto_enabled}} =
             FirstRun.reconcile_enablement(
               model_state: :local_ready,
               req_started?: fn -> true end,
               settings: Settings.defaults(),
               user_settings: %{},
               local_selection: local,
               context: %{audit?: false}
             )

    assert {:ok, response} = DirectAnswer.run(%{text: "Can you answer?"}, %{actor: "operator"})
    assert response.direct_answer.source == :model
    assert response.message == "first model answer"
  end

  test "fresh Home with nothing provisioned still returns the honest fallback" do
    assert {:ok, %{state: :nothing_detected}} =
             FirstRun.reconcile_enablement(
               model_state: :runtime_missing,
               req_started?: fn -> true end,
               settings: Settings.defaults(),
               user_settings: %{},
               hosted_selection: nil,
               context: %{audit?: false}
             )

    assert {:ok, response} = DirectAnswer.run(%{text: "Can you answer?"}, %{actor: "operator"})
    assert response.direct_answer.source == :bounded_fallback
    assert response.message =~ "direct-answer model is disabled"
  end

  test "fresh Home with an already-configured hosted provider answers through that profile" do
    assert {:ok, _setting} =
             Settings.put("providers.openai.enabled", true, %{audit?: false})

    assert {:ok, settings, user_settings} = Store.resolved_settings()

    hosted = %{
      profile: "fast",
      provider: "openai",
      provider_class: :hosted,
      verification: :configured_unverified
    }

    assert {:ok, %{state: :auto_enabled}} =
             FirstRun.reconcile_enablement(
               model_state: :runtime_missing,
               req_started?: fn -> true end,
               settings: settings,
               user_settings: user_settings,
               hosted_selection: hosted,
               context: %{audit?: false}
             )

    assert {:ok, response} = DirectAnswer.run(%{text: "Can you answer?"}, %{actor: "operator"})
    assert response.direct_answer.source == :model
    assert response.direct_answer.model_profile == "fast"
  end

  defp restore(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore(module, value), do: Application.put_env(:allbert_assist, module, value)
end
