defmodule AllbertAssist.Settings.ModelRolesTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Paths
  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Models
  alias AllbertAssist.Settings.Schema

  @env_vars ~w[
    ALLBERT_HOME
    ALLBERT_HOME_DIR
    ALLBERT_SETTINGS_ROOT
    ALLBERT_SETTINGS_MASTER_KEY
    ALLBERT_VAULT_BACKEND
    ANTHROPIC_API_KEY
    OPENAI_API_KEY
    OPENROUTER_API_KEY
    GOOGLE_API_KEY
    GEMINI_API_KEY
    OLLAMA_BASE_URL
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    System.put_env("ALLBERT_VAULT_BACKEND", "env")
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home =
      Path.join(System.tmp_dir!(), "allbert-model-roles-#{System.unique_integer([:positive])}")

    System.put_env("ALLBERT_HOME", home)
    Fragments.clear_cache()

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths)
      restore_app_env(Settings, original_settings)
      Fragments.clear_cache()
    end)

    :ok
  end

  test "model-role fragment is versioned, nil-default, and concrete-profile-only" do
    assert {:ok, 1} = Settings.get("model_roles.schema_version")

    for role <- ~w[fast capable thinking] do
      key = "model_roles.#{role}.profile"
      assert {:ok, nil} = Settings.get(key)
      assert Settings.safe_write_key?(key)
      assert {:ok, fragment} = Fragments.fragment_for_key(key)
      assert fragment.id == "core:model_roles"
      assert fragment.schema_version == 1
    end

    assert {:error,
            {:invalid_setting, "model_roles.fast.profile",
             {:role_reference_not_allowed, "role:capable"}}} =
             Settings.put("model_roles.fast.profile", "role:capable", %{audit?: false})

    assert {:error,
            {:invalid_setting, "model_roles.fast.profile",
             {:unknown_model_profile, "missing-profile"}}} =
             Settings.put("model_roles.fast.profile", "missing-profile", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("model_roles.fast.profile", "local", %{audit?: false})

    assert {:ok, "local"} = Settings.get("model_roles.fast.profile")
  end

  test "only task chains accept the closed role-reference vocabulary" do
    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.direct_answer",
               ["role:fast", "local"],
               %{audit?: false}
             )

    assert {:error,
            {:invalid_setting, "model_preferences.capabilities.text_generation",
             {:unknown_model_profile_in_list, ["role:fast"]}}} =
             Settings.put(
               "model_preferences.capabilities.text_generation",
               ["role:fast"],
               %{audit?: false}
             )

    assert {:error,
            {:invalid_setting, "model_preferences.primary", {:unknown_model_profile, "role:fast"}}} =
             Settings.put("model_preferences.primary", "role:fast", %{audit?: false})

    assert {:error,
            {:invalid_setting, "intent.direct_answer_model_profile",
             {:unknown_model_profile, "role:fast"}}} =
             Settings.put("intent.direct_answer_model_profile", "role:fast", %{audit?: false})

    assert {:error,
            {:invalid_setting, "model_preferences.tasks.direct_answer",
             {:unknown_model_profile_or_role_in_list, ["role:other"]}}} =
             Settings.put(
               "model_preferences.tasks.direct_answer",
               ["role:other"],
               %{audit?: false}
             )
  end

  test "unconfigured roles diagnose and continue, then resolve with role provenance" do
    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.direct_answer",
               ["role:fast", "local"],
               %{audit?: false}
             )

    assert {:ok, fallback} = Models.for(:direct_answer)
    assert fallback.profile_name == "local"
    refute Map.has_key?(fallback, :requested_role)

    assert [
             %{
               reason: :unconfigured_role,
               requested_reference: "role:fast",
               requested_role: "fast",
               resolved_profile: nil
             }
           ] = fallback.diagnostics

    assert {:ok, _setting} =
             Settings.put("model_roles.fast.profile", "local", %{audit?: false})

    assert {:ok, resolution} = Models.for(:direct_answer)
    assert resolution.profile_name == "local"
    assert resolution.requested_reference == "role:fast"
    assert resolution.requested_role == "fast"
    assert resolution.resolved_profile == "local"
    assert resolution.diagnostics == []

    assert {:ok, [only]} = Models.candidates_for(:direct_answer)
    assert only.requested_role == "fast"
    assert only.profile_name == "local"
  end

  test "role targets retain capability and provider checks with redacted provenance" do
    assert {:ok, _setting} =
             Settings.put("model_roles.thinking.profile", "voice_stt_fake", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.direct_answer",
               ["role:thinking", "local"],
               %{audit?: false}
             )

    assert {:ok, incapable_fallback} = Models.for(:direct_answer)
    assert incapable_fallback.profile_name == "local"

    assert Enum.any?(incapable_fallback.diagnostics, fn diagnostic ->
             diagnostic.requested_reference == "role:thinking" and
               diagnostic.requested_role == "thinking" and
               diagnostic.resolved_profile == "voice_stt_fake" and
               diagnostic.reason ==
                 {:profile_missing_capability, "voice_stt_fake", "text_generation"}
           end)

    assert {:ok, _setting} =
             Settings.put("model_roles.capable.profile", "fast", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.direct_answer",
               ["role:capable", "local"],
               %{audit?: false}
             )

    assert {:ok, disabled_fallback} = Models.for(:direct_answer)
    assert disabled_fallback.profile_name == "local"

    assert Enum.any?(disabled_fallback.diagnostics, fn diagnostic ->
             diagnostic.requested_reference == "role:capable" and
               diagnostic.requested_role == "capable" and
               diagnostic.resolved_profile == "fast" and
               diagnostic.reason == {:provider_disabled, "fast", "openai"}
           end)
  end

  test "concrete namespace and result bytes remain unchanged" do
    assert {:ok, before} = Models.for(:direct_answer)
    before_bytes = :erlang.term_to_binary(before, [:deterministic])

    assert {:ok, _setting} =
             Settings.put("model_roles.fast.profile", "local", %{audit?: false})

    assert {:ok, after_mapping_only} = Models.for(:direct_answer)
    assert :erlang.term_to_binary(after_mapping_only, [:deterministic]) == before_bytes

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.direct_answer",
               ["fast", "role:fast"],
               %{audit?: false}
             )

    assert {:ok, collision_resolution} = Models.for(:direct_answer)
    assert collision_resolution.profile_name == "local"
    assert collision_resolution.requested_reference == "role:fast"
    assert collision_resolution.requested_role == "fast"
  end

  test "central reference seam diagnoses a persisted missing role target" do
    settings =
      Schema.defaults()
      |> Schema.put_dotted("model_roles.fast.profile", "removed-profile")

    assert {:skip,
            %{
              reason: :missing_profile,
              requested_reference: "role:fast",
              requested_role: "fast",
              resolved_profile: "removed-profile"
            }} = Models.resolve_reference("role:fast", settings)
  end

  test "changing a referenced role reconciles the provider-egress disclosure route" do
    System.put_env("OPENAI_API_KEY", "role-disclosure-test-key")

    assert {:ok, _setting} =
             Settings.put("providers.openai.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("intent.direct_answer_model_enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.direct_answer",
               ["role:fast"],
               %{audit?: false}
             )

    refute Disclosure.hosted_pending?(:cli)

    assert {:ok, _setting} =
             Settings.put("model_roles.fast.profile", "fast", %{audit?: false})

    assert Disclosure.hosted_pending?(:cli)
  end

  defp restore_env(values) do
    Enum.each(values, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
