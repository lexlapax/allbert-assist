defmodule AllbertAssist.FirstRun.FlagshipCoreTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.{ModelRuntime, Models}
  alias AllbertAssist.Settings.Store

  @provider_env_vars ~w(
    ALLBERT_VAULT_BACKEND
    ANTHROPIC_API_KEY
    OPENAI_API_KEY
    OPENROUTER_API_KEY
    GOOGLE_API_KEY
    GEMINI_API_KEY
  )

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
    provider_env = Map.new(@provider_env_vars, &{&1, System.get_env(&1)})
    Application.put_env(:allbert_assist, Settings, root: root)
    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, DirectAnswer, answerer: Answerer)
    Enum.each(@provider_env_vars, &System.delete_env/1)
    System.put_env("ALLBERT_VAULT_BACKEND", "env")

    on_exit(fn ->
      restore(Settings, settings_env)
      restore(Paths, paths_env)
      restore(DirectAnswer, answer_env)
      restore_env(provider_env)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "fresh Home with a usable local profile answers the first question with zero clicks" do
    local = %{
      profile: "direct_answer_local",
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
               local_selection: nil,
               hosted_selection: nil,
               context: %{audit?: false}
             )

    assert {:ok, response} = DirectAnswer.run(%{text: "Can you answer?"}, %{actor: "operator"})
    assert response.direct_answer.source == :bounded_fallback
    assert response.message =~ "direct-answer model is disabled"
  end

  test "every supported hosted env key enables only its explicitly selected task profile" do
    rows = [
      {"OPENAI_API_KEY", "openai", "fast"},
      {"ANTHROPIC_API_KEY", "anthropic", "anthropic_fast"},
      {"OPENROUTER_API_KEY", "openrouter", "openrouter_fast"},
      {"GEMINI_API_KEY", "gemini", "coding"},
      {"GOOGLE_API_KEY", "gemini", "coding"}
    ]

    for {env_key, provider, profile} <- rows do
      File.rm_rf!(Store.root())
      Enum.each(@provider_env_vars -- ["ALLBERT_VAULT_BACKEND"], &System.delete_env/1)
      System.put_env(env_key, "operator-env-key-#{env_key}")

      assert :byok_ready ==
               FirstRun.first_model_state(
                 ollama_probe: fn -> :missing end,
                 hardware_ok?: fn -> true end
               )

      assert {:ok, _settings} =
               Store.write_user_settings(%{
                 "model_preferences" => %{"tasks" => %{"direct_answer" => [profile]}}
               })

      assert {:ok, settings, user_settings} = Store.resolved_settings()
      assert get_in(user_settings, ["model_preferences", "tasks", "direct_answer"]) == [profile]
      assert get_in(settings, ["providers", provider, "enabled"]) == false

      assert {:ok,
              %{
                state: :auto_enabled,
                selection: %{
                  profile: ^profile,
                  provider: ^provider,
                  provider_class: :hosted
                }
              }} =
               FirstRun.reconcile_enablement(
                 model_state: :byok_ready,
                 req_started?: fn -> true end,
                 settings: settings,
                 user_settings: user_settings,
                 context: %{audit?: false}
               )

      assert {:ok, persisted} = Store.read_user_settings()
      assert get_in(persisted, ["providers", provider, "enabled"]) == nil

      assert {:ok, resolution} = Models.for(:direct_answer)
      assert resolution.profile.name == profile

      assert ModelRuntime.request_opts(resolution.profile)[:api_key] ==
               "operator-env-key-#{env_key}"

      assert :ok =
               Disclosure.render_and_ack(:cli, fn text ->
                 assert text =~
                          "Your configured DirectAnswer route uses #{profile} from #{provider}."

                 :ok
               end)

      assert {:ok, response} =
               DirectAnswer.run(%{text: "Can you answer?"}, %{actor: "operator"})

      assert response.direct_answer.source == :model
      assert response.direct_answer.model_profile == profile
    end
  end

  defp restore(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp restore_env(env) do
    Enum.each(env, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end
end
