defmodule AllbertAssist.Actions.SettingsActionsTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Settings.Doctor, as: SettingsDoctorAction
  alias AllbertAssist.Actions.Settings.DoctorModelProfile
  alias AllbertAssist.Actions.Settings.ExplainSetting
  alias AllbertAssist.Actions.Settings.ListModelProfiles
  alias AllbertAssist.Actions.Settings.ListProviderProfiles
  alias AllbertAssist.Actions.Settings.ListSettings
  alias AllbertAssist.Actions.Settings.ModelDoctor, as: ModelDoctorAction
  alias AllbertAssist.Actions.Settings.ReadSetting
  alias AllbertAssist.Actions.Settings.ResolvedSettingsSnapshot
  alias AllbertAssist.Actions.Settings.SetActiveModelProfile
  alias AllbertAssist.Actions.Settings.SetDirectAnswerModelProfile
  alias AllbertAssist.Actions.Settings.SetProviderCredential
  alias AllbertAssist.Actions.Settings.UpdateSetting
  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.DoctorDiagnostics
  alias AllbertAssist.TestSupport.ReadyEffectContext

  @ready_context_key {__MODULE__, :ready_effect_context}

  setup {Req.Test, :verify_on_exit!}

  # Provider keys can be env-provided (Vault tier 3); since v0.63 F2 the doctor resolves
  # them, so a "missing credential" test must clear them or the ambient shell/CI env makes
  # it non-deterministic.
  @provider_env_keys ~w(ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY GEMINI_API_KEY)
  @runtime_env_keys ~w(OLLAMA_BASE_URL)

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_paths_config = Application.get_env(:allbert_assist, Paths)

    original_model_env =
      Map.new(@provider_env_keys ++ @runtime_env_keys, &{&1, System.get_env(&1)})

    Enum.each(@provider_env_keys ++ @runtime_env_keys, &System.delete_env/1)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-settings-actions-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: root)
    Application.put_env(:allbert_assist, Paths, home: root)
    Process.put(@ready_context_key, ReadyEffectContext.context())

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      restore_env(Paths, original_paths_config)

      Enum.each(original_model_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(root)
    end)

    :ok
  end

  test "list/read/explain settings actions return settings metadata" do
    assert {:ok, list_response} = ListSettings.run(%{}, %{})
    assert list_response.status == :completed
    assert list_response.message =~ "Settings Central has"
    assert list_response.message =~ "won't dump the full operator report"
    refute list_response.message =~ "operator.timezone"
    refute list_response.message =~ "model_profiles.fast.max_tokens"
    refute list_response.message =~ "api_key_ref"
    assert length(list_response.settings) <= 25

    assert [
             %{
               name: "list_settings",
               settings_metadata: %{count: count, render_mode: :assistant_summary}
             }
           ] = list_response.actions

    assert count > 0

    assert {:ok, bounded_response} =
             ListSettings.run(%{render_mode: "operator_report"}, %{})

    assert bounded_response.status == :completed
    assert bounded_response.message =~ "won't dump the full operator report"

    assert [
             %{
               name: "list_settings",
               settings_metadata: %{render_mode: :assistant_summary}
             }
           ] = bounded_response.actions

    assert {:ok, report_response} =
             ListSettings.run(Map.put(operator_report_params(), :namespace, "operator"), %{})

    assert report_response.status == :completed
    assert report_response.message =~ "Settings Central values:"
    assert report_response.message =~ "operator.timezone"

    assert {:ok, model_report_response} =
             ListSettings.run(
               Map.put(operator_report_params(), :namespace, "model_profiles.fast"),
               %{}
             )

    assert model_report_response.message =~ "model_profiles.fast.max_tokens: 1024"

    assert {:ok, provider_report_response} =
             ListSettings.run(
               Map.put(operator_report_params(), :namespace, "providers.openai"),
               %{}
             )

    assert provider_report_response.message =~ "providers.openai.api_key_ref: \"[REDACTED]\""

    assert [
             %{
               name: "list_settings",
               settings_metadata: %{render_mode: :operator_report}
             }
           ] = report_response.actions

    assert {:ok, read_response} = ReadSetting.run(%{key: "operator.timezone"}, %{})
    assert read_response.status == :completed
    assert read_response.message =~ "America/Los_Angeles"
    assert read_response.setting.key == "operator.timezone"

    assert {:ok, explain_response} = ExplainSetting.run(%{key: "operator.timezone"}, %{})
    assert explain_response.status == :completed
    assert explain_response.message =~ "Layers:"
    assert explain_response.setting.layers != []

    assert {:ok, deprecated_response} =
             ExplainSetting.run(%{key: "memory.auto_promote_sensitive_entries"}, %{})

    assert deprecated_response.status == :completed
    assert deprecated_response.setting.deprecated?
    assert deprecated_response.message =~ "Deprecated:"
    assert deprecated_response.message =~ "grants no authority"

    assert {:ok, snapshot_response} = ResolvedSettingsSnapshot.run(%{}, %{})
    assert snapshot_response.status == :completed
    assert snapshot_response.settings["operator"]["timezone"] == "America/Los_Angeles"

    assert [
             %{
               name: "resolved_settings_snapshot",
               permission: :read_only,
               settings_metadata: %{user_settings?: false}
             }
           ] = snapshot_response.actions
  end

  test "update setting writes safe key and rejects read-only key" do
    context =
      attach_ready(%{request: %{operator_id: "local", channel: :test, input_signal_id: "sig"}})

    assert {:ok, response} =
             UpdateSetting.run(%{key: "operator.communication_style", value: "balanced"}, context)

    assert response.status == :completed
    assert response.message =~ "Updated operator.communication_style"
    assert response.setting.key == "operator.communication_style"
    assert {:ok, "balanced"} = Settings.get("operator.communication_style")

    assert {:ok, denied} =
             UpdateSetting.run(%{key: "agents.primary_intent.module", value: "Other"}, context)

    assert denied.status == :denied
    assert denied.message =~ "read_only_setting"
  end

  test "update setting writes Settings Central permission keys" do
    context =
      attach_ready(%{request: %{operator_id: "local", channel: :test, input_signal_id: "sig"}})

    assert {:ok, response} =
             UpdateSetting.run(%{key: "permissions.external_network", value: "denied"}, context)

    assert response.status == :completed
    assert response.setting.key == "permissions.external_network"
    assert {:ok, "denied"} = Settings.get("permissions.external_network")

    assert {:ok, skill_response} =
             UpdateSetting.run(
               %{key: "permissions.skill_write", value: "needs_confirmation"},
               context
             )

    assert skill_response.status == :completed
    assert skill_response.setting.key == "permissions.skill_write"
    assert {:ok, "needs_confirmation"} = Settings.get("permissions.skill_write")

    assert {:ok, denied} =
             UpdateSetting.run(%{key: "permissions.external_network", value: "purple"}, context)

    assert denied.status == :denied
    assert denied.message =~ "invalid_setting"
  end

  test "provider profile action returns only redacted credential status" do
    assert {:ok, response} = ListProviderProfiles.run(%{}, %{})

    assert response.status == :completed
    assert response.message =~ "Provider registry has"
    assert response.message =~ "won't dump the full operator report"
    refute response.message =~ "endpoint_kind=credentialed_remote"
    refute response.message =~ "credential=missing"
    assert Enum.any?(response.providers, &(&1.name == "openai"))
    refute response.message =~ "api_key"
    refute Enum.any?(response.providers, &Map.has_key?(&1, :base_url))
    refute Enum.any?(response.providers, &Map.has_key?(&1, :api_key_ref))

    assert [
             %{
               name: "list_provider_profiles",
               settings_metadata: %{render_mode: :assistant_summary}
             }
           ] = response.actions

    assert {:ok, bounded_response} =
             ListProviderProfiles.run(%{render_mode: "operator_report"}, %{})

    assert bounded_response.message =~ "won't dump the full operator report"

    assert [
             %{
               name: "list_provider_profiles",
               settings_metadata: %{render_mode: :assistant_summary}
             }
           ] = bounded_response.actions

    assert {:ok, report_response} =
             ListProviderProfiles.run(operator_report_params(), %{})

    assert report_response.message =~ "Provider profiles:"
    assert report_response.message =~ "endpoint_kind=credentialed_remote"
    assert report_response.message =~ "credential=missing"
    refute report_response.message =~ "api_key"
    refute Enum.any?(report_response.providers, &Map.has_key?(&1, :base_url))
    refute Enum.any?(report_response.providers, &Map.has_key?(&1, :api_key_ref))
  end

  test "model profile action returns only redacted credential status" do
    assert {:ok, response} = ListModelProfiles.run(%{}, %{})

    assert response.status == :completed
    assert response.message =~ "Model registry has"
    assert response.message =~ "won't dump the full operator report"
    refute response.message =~ "endpoint_kind=local_endpoint"
    refute response.message =~ "credential=missing"
    assert Enum.any?(response.models, &(&1.name == "fast"))
    refute response.message =~ "api_key"
    refute Enum.any?(response.models, &Map.has_key?(&1, :provider_base_url))
    refute Enum.any?(response.models, &Map.has_key?(&1, :provider_api_key_ref))

    assert [
             %{
               name: "list_model_profiles",
               settings_metadata: %{render_mode: :assistant_summary}
             }
           ] = response.actions

    assert {:ok, bounded_response} = ListModelProfiles.run(%{render_mode: "operator_report"}, %{})

    assert bounded_response.message =~ "won't dump the full operator report"

    assert [
             %{
               name: "list_model_profiles",
               settings_metadata: %{render_mode: :assistant_summary}
             }
           ] = bounded_response.actions

    assert {:ok, report_response} = ListModelProfiles.run(operator_report_params(), %{})

    assert report_response.message =~ "Model profiles:"
    assert report_response.message =~ "endpoint_kind=local_endpoint"
    assert report_response.message =~ "credential=missing"
    refute report_response.message =~ "api_key"
    refute Enum.any?(report_response.models, &Map.has_key?(&1, :provider_base_url))
    refute Enum.any?(report_response.models, &Map.has_key?(&1, :provider_api_key_ref))
  end

  test "model doctor reports the recommendation matrix without leaking secrets" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/api/tags"

      Req.Test.json(conn, %{
        "models" => [
          %{"model" => "nomic-embed-text:latest", "context_length" => 2048},
          %{"model" => "llama3.1:8b", "context_length" => 128_000},
          %{"model" => "gemma4:26b", "context_length" => 256_000},
          %{"model" => "qwen2.5:7b", "context_length" => 32_768}
        ]
      })
    end)

    assert {:ok, response} =
             ModelDoctorAction.run(
               %{},
               attach_ready(%{req_options: [plug: {Req.Test, __MODULE__}]})
             )

    assert response.status == :completed
    assert response.message =~ "Model doctor checked"
    assert response.message =~ "won't dump the operator matrix"
    refute response.message =~ "intent_embedding status=ok"
    assert response.model_doctor.summary["ok"] >= 3
    assert [%{render_mode: :assistant_summary}] = response.actions

    rows = Map.new(response.model_doctor.rows, &{&1.id, &1})
    assert rows["intent_embedding"].recommended_model == "nomic-embed-text"
    assert rows["intent_disambiguation"].recommended_model == "llama3.1:8b"
    assert rows["intent_escalation"].recommended_model == "gemma4:26b"
    assert rows["pi_mode_coding"].recommended_profile == "pi_coding_local"
    assert rows["pi_mode_coding"].settings_key == "coding.model_profile"

    for role <- ~w[fanout_manager fanout_synthesis] do
      row = Map.fetch!(rows, role)

      assert row.role == role
      assert row.chain_kind == "closed_task"
      assert row.settings_key == "model_preferences.tasks.#{role}"
      assert row.configured_profiles == ["direct_answer_local"]
      assert row.resolution_status == "resolved"
      assert row.resolved_profile == "direct_answer_local"
      assert row.resolved_model == "qwen2.5:7b"
      assert row.role_readiness == row.status
      assert row.unavailable_role == nil
      assert row.auto_pull == false
    end

    refute inspect(response) =~ "secret://"
    refute inspect(response) =~ "api_key"
    refute inspect(response) =~ "sk-"
    refute response.message =~ "http://"

    assert {:ok, report_response} =
             ModelDoctorAction.run(
               operator_report_params(),
               attach_ready(%{req_options: [plug: {Req.Test, __MODULE__}]})
             )

    assert report_response.message =~ "model doctor ok="
    assert report_response.message =~ "intent_embedding status=ok"
    assert report_response.message =~ "intent_escalation status=ok"
    assert [%{render_mode: :operator_report}] = report_response.actions
  end

  test "model doctor names the exact unavailable closed fan-out role without pulling" do
    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.fanout_manager",
               ["fast", "direct_answer_local"],
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.fanout_synthesis",
               ["fast"],
               ReadyEffectContext.attach(%{audit?: false})
             )

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/tags"

      Req.Test.json(conn, %{
        "models" => [
          %{"model" => "qwen2.5:7b", "context_length" => 32_768},
          %{"model" => "nomic-embed-text", "context_length" => 2_048},
          %{"model" => "llama3.1:8b", "context_length" => 128_000},
          %{"model" => "gemma4:26b", "context_length" => 256_000}
        ]
      })
    end)

    assert {:ok, response} =
             ModelDoctorAction.run(
               operator_report_params(),
               attach_ready(%{req_options: [plug: {Req.Test, __MODULE__}]})
             )

    rows = Map.new(response.model_doctor.rows, &{&1.id, &1})

    assert rows["fanout_manager"].resolution_status == "resolved"
    assert rows["fanout_manager"].configured_profiles == ["fast", "direct_answer_local"]
    assert rows["fanout_manager"].configured_profile == "fast"
    assert rows["fanout_manager"].resolved_profile == "direct_answer_local"
    assert rows["fanout_manager"].role_readiness == "ok"
    assert rows["fanout_manager"].unavailable_role == nil

    assert %{
             role: "fanout_synthesis",
             chain_kind: "closed_task",
             settings_key: "model_preferences.tasks.fanout_synthesis",
             configured_profile: "fast",
             configured_profiles: ["fast"],
             resolution_status: "unavailable",
             resolved_profile: nil,
             resolved_model: nil,
             resolved_provider: nil,
             role_readiness: "missing",
             unavailable_role: "fanout_synthesis",
             auto_pull: false,
             status: "missing",
             doctor: nil
           } = rows["fanout_synthesis"]

    assert rows["fanout_synthesis"].diagnostics == ["task role fanout_synthesis is unavailable"]

    assert response.message =~
             "fanout_synthesis status=missing chain=[fast] resolved=none unavailable-role=fanout_synthesis auto-pull=false key=model_preferences.tasks.fanout_synthesis"

    assert response.message =~
             "fanout_manager status=ok chain=[fast,direct_answer_local] resolved=direct_answer_local(qwen2.5:7b) unavailable-role=none auto-pull=false key=model_preferences.tasks.fanout_manager"

    refute inspect(response) =~ "secret://"
    refute inspect(response) =~ "api_key"
  end

  test "resolved hosted and capable alternate fan-out roles remain available warnings" do
    assert {:ok, _secret} =
             Settings.Secrets.put_secret(
               "secret://providers/openai/api_key",
               "operator-test-key",
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "providers.openai.enabled",
               true,
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.fanout_manager",
               ["fast"],
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.fanout_synthesis",
               ["coding_local"],
               ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/tags"

      Req.Test.json(conn, %{
        "models" => [
          %{"model" => "qwen2.5:7b", "context_length" => 32_768},
          %{"model" => "qwen2.5-coder:7b", "context_length" => 32_768},
          %{"model" => "nomic-embed-text", "context_length" => 2_048},
          %{"model" => "llama3.1:8b", "context_length" => 128_000},
          %{"model" => "gemma4:26b", "context_length" => 256_000}
        ]
      })
    end)

    assert {:ok, response} =
             ModelDoctorAction.run(
               %{},
               attach_ready(%{req_options: [plug: {Req.Test, __MODULE__}]})
             )

    rows = Map.new(response.model_doctor.rows, &{&1.id, &1})

    assert %{
             configured_profiles: ["fast"],
             resolution_status: "resolved",
             resolved_profile: "fast",
             resolved_provider: "openai",
             role_readiness: "remote-egress-warning",
             unavailable_role: nil,
             auto_pull: false,
             doctor: nil
           } = rows["fanout_manager"]

    assert %{
             configured_profiles: ["coding_local"],
             resolution_status: "resolved",
             resolved_profile: "coding_local",
             resolved_model: "qwen2.5-coder:7b",
             role_readiness: "ok",
             unavailable_role: nil,
             auto_pull: false
           } = rows["fanout_synthesis"]

    assert rows["fanout_synthesis"].recommended_profile == "direct_answer_local"
    assert rows["fanout_synthesis"].recommended_model == "qwen2.5:7b"
    refute inspect(response) =~ "secret://"
    refute inspect(response) =~ "api_key"
  end

  test "settings doctor reports fragment version contract without leaking secrets" do
    assert {:ok, response} = SettingsDoctorAction.run(%{}, %{})

    assert response.status == :completed
    assert response.message =~ "Settings doctor checked"
    assert response.settings_version.status == :ok
    assert response.settings_version.counts.forward == 0
    assert Enum.any?(response.settings_version.inventory, &(&1.fragment_id == "core:artifacts"))
    assert [%{settings_version_status: :ok}] = response.actions

    assert {:ok, report_response} =
             SettingsDoctorAction.run(operator_report_params(), %{})

    assert report_response.message =~ "settings version contract status=ok"
    assert report_response.message =~ "core:artifacts"
    refute inspect(report_response) =~ "secret://"
    refute inspect(report_response) =~ "api_key"
  end

  test "model doctor prioritizes callability failures over recommendation strength" do
    assert {:ok, _setting} =
             Settings.put(
               "intent.router_embedding_profile",
               "local",
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "intent.router_escalation_profile",
               "fast",
               ReadyEffectContext.attach(%{audit?: false})
             )

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/api/tags"
      Req.Test.json(conn, %{"models" => []})
    end)

    assert {:ok, response} =
             ModelDoctorAction.run(
               %{},
               attach_ready(%{req_options: [plug: {Req.Test, __MODULE__}]})
             )

    rows = Map.new(response.model_doctor.rows, &{&1.id, &1})

    assert rows["intent_embedding"].status == "not-pulled"
    assert rows["intent_disambiguation"].status == "not-pulled"
    assert rows["intent_escalation"].status == "unavailable"
    assert rows["intent_escalation"].endpoint_kind == "credentialed_remote"

    assert "configured provider is disabled" in rows["intent_escalation"].diagnostics

    assert rows["direct_answer"].configured_profile == "direct_answer_local"
    assert rows["direct_answer"].configured_model == "qwen2.5:7b"
    assert rows["direct_answer"].status == "not-pulled"

    for role <- ~w[fanout_manager fanout_synthesis] do
      row = Map.fetch!(rows, role)

      assert row.resolution_status == "resolved"
      assert row.resolved_profile == "direct_answer_local"
      assert row.role_readiness == "not-pulled"
      assert row.unavailable_role == role
      assert row.auto_pull == false
    end

    refute inspect(response) =~ "secret://"
  end

  test "doctor diagnostics use the fixed ADR 0047 catalog" do
    assert :credential_missing in DoctorDiagnostics.codes()
    assert :endpoint_unreachable in DoctorDiagnostics.codes()

    for {code, message} <- DoctorDiagnostics.catalog() do
      assert DoctorDiagnostics.known?(code)
      assert DoctorDiagnostics.new(code) == %{code: code, message: message}
      assert byte_size(message) <= 256
      refute message =~ "http://"
      refute message =~ "https://"
      refute message =~ "/v1"
      refute message =~ "token="
      refute message =~ "sk-"
    end

    refute DoctorDiagnostics.known?(:provider_returned_secret_body)
    assert DoctorDiagnostics.new(:provider_returned_secret_body).code == :doctor_failed
  end

  test "set active model profile writes safe settings and provider enablement" do
    assert {:ok, set_active} =
             SetActiveModelProfile.run(
               %{profile: "local", enable_assist: true},
               attach_ready(%{actor: "local", channel: :test})
             )

    assert set_active.status == :completed
    assert set_active.provider == "local_ollama"
    assert {:ok, "local"} = Settings.get("intent.model_profile")
    assert {:ok, "local"} = Settings.get("model_preferences.primary")
    assert {:ok, "local"} = Settings.get("intent.direct_answer_model_profile")
    assert {:ok, ["local"]} = Settings.get("model_preferences.tasks.direct_answer")
    assert {:ok, true} = Settings.get("intent.model_assist_enabled")
    assert {:ok, true} = Settings.get("providers.local_ollama.enabled")
    assert Enum.any?(set_active.settings, &(&1.key == "intent.model_profile"))

    assert Enum.any?(
             set_active.settings,
             &(&1.key == "model_preferences.tasks.direct_answer")
           )
  end

  test "set active model preserves the operator-authored DirectAnswer fallback tail" do
    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.direct_answer",
               ["fast", "local"],
               ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    assert {:ok, response} =
             SetActiveModelProfile.run(
               %{profile: "local"},
               attach_ready(%{actor: "local", channel: :cli})
             )

    assert response.status == :completed

    assert {:ok, ["local", "fast"]} =
             Settings.get("model_preferences.tasks.direct_answer")
  end

  test "purpose-owned DirectAnswer selection leaves global primary unchanged and reconciles disclosure" do
    assert {:ok, _setting} =
             Settings.put(
               "intent.direct_answer_model_enabled",
               true,
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.direct_answer",
               ["local", "fast"],
               ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    assert {:ok, response} =
             SetDirectAnswerModelProfile.run(
               %{profile: "fast"},
               attach_ready(%{actor: "local", channel: :cli})
             )

    assert response.status == :completed
    assert response.profile == "fast"
    assert response.provider == "openai"
    assert response.chain == ["fast", "local"]
    assert response.disclosure.status == :reconciled
    assert response.disclosure.surface == "cli"
    assert response.disclosure.hosted_pending?
    assert Disclosure.hosted_pending?(:cli)
    assert {:ok, "local"} = Settings.get("model_preferences.primary")

    assert {:ok, ["fast", "local"]} =
             Settings.get("model_preferences.tasks.direct_answer")

    assert {:ok, true} = Settings.get("providers.openai.enabled")
  end

  test "purpose-owned DirectAnswer selection rejects non-text profiles before writes" do
    assert {:ok, response} =
             SetDirectAnswerModelProfile.run(%{profile: "voice_stt_fake"}, %{
               actor: "local",
               channel: :cli
             })

    assert response.status == :denied
    assert response.message =~ "profile_missing_capability"
    assert {:ok, %{}} = Settings.read_user_settings()
  end

  test "set active model validates assist input before any durable write" do
    assert {:ok, response} =
             SetActiveModelProfile.run(%{profile: "local", enable_assist: "maybe"}, %{
               actor: "local",
               channel: :test
             })

    assert response.status == :denied
    assert response.message =~ "invalid_boolean"
    assert {:ok, %{}} = Settings.read_user_settings()
  end

  test "set active model rejects a non-text profile before any durable write" do
    assert {:ok, response} =
             SetActiveModelProfile.run(%{profile: "voice_stt_fake", enable_assist: true}, %{
               actor: "local",
               channel: :test
             })

    assert response.status == :denied
    assert response.message =~ "profile_missing_capability"
    assert response.message =~ "text_generation"
    assert {:ok, %{}} = Settings.read_user_settings()
  end

  test "set active model preserves the legacy implicit-text profile contract" do
    assert {:ok, _settings} =
             Settings.write_user_settings(
               %{
                 "model_profiles" => %{
                   "legacy_text" => %{
                     "provider" => "local_ollama",
                     "model" => "legacy-text:latest"
                   }
                 }
               },
               [],
               ReadyEffectContext.context()
             )

    assert {:ok, response} =
             SetActiveModelProfile.run(
               %{profile: "legacy_text"},
               attach_ready(%{actor: "local", channel: :test})
             )

    assert response.status == :completed
    assert response.message =~ "legacy_text"

    assert {:ok, persisted} = Settings.read_user_settings()
    assert get_in(persisted, ["model_preferences", "primary"]) == "legacy_text"

    assert get_in(persisted, ["model_preferences", "tasks", "direct_answer"]) == [
             "legacy_text"
           ]
  end

  test "purpose-owned DirectAnswer selection preserves the legacy implicit-text profile contract" do
    assert {:ok, _settings} =
             Settings.write_user_settings(
               %{
                 "model_profiles" => %{
                   "legacy_text" => %{
                     "provider" => "local_ollama",
                     "model" => "legacy-text:latest"
                   }
                 }
               },
               [],
               ReadyEffectContext.context()
             )

    assert {:ok, response} =
             SetDirectAnswerModelProfile.run(
               %{profile: "legacy_text"},
               attach_ready(%{actor: "local", channel: :cli})
             )

    assert response.status == :completed
    assert response.profile == "legacy_text"
    assert response.provider == "local_ollama"
    assert response.chain == ["legacy_text"]
    assert {:ok, true} = Settings.get("providers.local_ollama.enabled")
    assert {:ok, "local"} = Settings.get("model_preferences.primary")
    assert {:ok, ["legacy_text"]} = Settings.get("model_preferences.tasks.direct_answer")
  end

  test "direct-answer doctor distinguishes the qualified model from global local" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/tags"

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{"models" => [%{"model" => "llama3.2:3b"}]})
      )
    end)

    context = attach_ready(%{req_options: [plug: {Req.Test, __MODULE__}]})

    assert {:ok, missing} =
             DoctorModelProfile.run(%{profile: "direct_answer_local"}, context)

    assert missing.doctor.endpoint_ok
    assert missing.doctor.model_available == false
    assert [%{code: :local_model_missing}] = missing.doctor.diagnostics

    Req.Test.expect(__MODULE__, fn conn ->
      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{"models" => [%{"model" => "qwen2.5:7b"}]})
      )
    end)

    assert {:ok, present} =
             DoctorModelProfile.run(%{profile: "direct_answer_local"}, context)

    assert present.doctor.model_available == true
    assert present.doctor.diagnostics == []
  end

  test "local endpoint doctor distinguishes missing and present Ollama models" do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/tags"

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{"models" => [%{"model" => "mistral:7b"}]})
      )
    end)

    context = attach_ready(%{req_options: [plug: {Req.Test, __MODULE__}]})

    assert {:ok, missing} = DoctorModelProfile.run(%{profile: "local"}, context)
    assert missing.status == :completed
    assert missing.doctor.endpoint_kind == :local_endpoint
    assert missing.doctor.effective_endpoint_class == :local
    assert missing.doctor.credential_ok == nil
    assert missing.doctor.endpoint_ok
    assert missing.doctor.model_available == false
    assert [%{code: :local_model_missing}] = missing.doctor.diagnostics

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/api/tags"

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{"models" => [%{"model" => "llama3.2:3b", "context_length" => 8192}]})
      )
    end)

    assert {:ok, present} = DoctorModelProfile.run(%{profile: "local"}, context)
    assert present.doctor.model_available == true
    assert present.doctor.context_window == 8192
    assert present.doctor.diagnostics == []
  end

  test "credentialed remote doctor lists provider models without leaking secrets" do
    assert {:ok, _secret} =
             Settings.Secrets.put_secret(
               "secret://providers/anthropic/api_key",
               "sk-ant-test-key",
               ReadyEffectContext.attach(%{
                 actor: "local",
                 channel: :test
               })
             )

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/models"
      assert {"x-api-key", "sk-ant-test-key"} in conn.req_headers
      assert {"anthropic-version", "2023-06-01"} in conn.req_headers

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "data" => [
            %{"id" => "claude-haiku-4-5-20251001", "context_window" => 200_000}
          ]
        })
      )
    end)

    assert {:ok, doctor} =
             DoctorModelProfile.run(
               %{profile: "anthropic_fast"},
               attach_ready(%{req_options: [plug: {Req.Test, __MODULE__}]})
             )

    assert doctor.status == :completed
    assert doctor.doctor.endpoint_kind == :credentialed_remote
    assert doctor.doctor.effective_endpoint_class == :hosted
    assert doctor.doctor.credential_ok
    assert doctor.doctor.endpoint_ok
    assert doctor.doctor.model_available == true
    assert doctor.doctor.context_window == 200_000
    refute inspect(doctor) =~ "sk-ant-test-key"
  end

  test "credentialed remote doctor resolves catalog aliases against provider model ids" do
    assert {:ok, _setting} =
             Settings.put(
               "model_profiles.anthropic_fast.model",
               "claude-haiku-4-5",
               ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    assert {:ok, _secret} =
             Settings.Secrets.put_secret(
               "secret://providers/anthropic/api_key",
               "sk-ant-test-key",
               ReadyEffectContext.attach(%{
                 actor: "local",
                 channel: :test
               })
             )

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/models"

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "data" => [
            %{"id" => "claude-haiku-4-5-20251001", "context_window" => 200_000}
          ]
        })
      )
    end)

    assert {:ok, doctor} =
             DoctorModelProfile.run(
               %{profile: "anthropic_fast"},
               attach_ready(%{req_options: [plug: {Req.Test, __MODULE__}]})
             )

    assert doctor.doctor.model_available == true
    assert doctor.doctor.diagnostics == []
  end

  test "credentialed remote doctor supports Gemini model catalog without leaking secrets" do
    assert {:ok, _secret} =
             Settings.Secrets.put_secret(
               "secret://providers/gemini/api_key",
               "AIza-test-key",
               ReadyEffectContext.attach(%{
                 actor: "local",
                 channel: :test
               })
             )

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v1beta/models"
      assert {"x-goog-api-key", "AIza-test-key"} in conn.req_headers

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{
          "models" => [
            %{"name" => "models/gemini-3.5-flash", "inputTokenLimit" => 1_048_576}
          ]
        })
      )
    end)

    assert {:ok, doctor} =
             DoctorModelProfile.run(
               %{profile: "coding"},
               attach_ready(%{req_options: [plug: {Req.Test, __MODULE__}]})
             )

    assert doctor.status == :completed
    assert doctor.provider == "gemini"
    assert doctor.doctor.endpoint_kind == :credentialed_remote
    assert doctor.doctor.credential_ok
    assert doctor.doctor.endpoint_ok
    assert doctor.doctor.model_available == true
    refute inspect(doctor) =~ "AIza-test-key"
  end

  test "doctor action errors do not echo unresolved profile input" do
    assert {:ok, failed} =
             DoctorModelProfile.run(%{profile: "sk-test-secret-profile"}, %{})

    assert failed.status == :error
    assert failed.message == "Model profile doctor failed."
    assert failed.diagnostics == [DoctorDiagnostics.new(:doctor_failed)]
    refute inspect(failed) =~ "sk-test-secret-profile"
  end

  test "credentialed remote doctor fails closed for missing credentials and private hosts" do
    assert {:ok, missing} = DoctorModelProfile.run(%{profile: "fast"}, %{})
    assert missing.status == :completed
    assert missing.doctor.credential_ok == false
    assert missing.doctor.endpoint_ok == false
    assert [%{code: :credential_missing}] = missing.doctor.diagnostics

    assert {:ok, _setting} =
             Settings.put(
               "providers.openai.base_url",
               "http://127.0.0.1:11434/v1",
               ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    assert {:ok, _secret} =
             Settings.Secrets.put_secret(
               "secret://providers/openai/api_key",
               "sk-test-private",
               ReadyEffectContext.attach(%{
                 actor: "local",
                 channel: :test
               })
             )

    assert {:ok, denied} = DoctorModelProfile.run(%{profile: "fast"}, %{})
    assert denied.status == :completed
    assert denied.doctor.endpoint_ok == false
    assert [%{code: :provider_host_denied}] = denied.doctor.diagnostics

    for host <- [
          "::ffff:127.0.0.1",
          "::ffff:10.0.0.1",
          "::ffff:169.254.169.254",
          "::ffff:0.0.0.0",
          "::ffff:100.64.0.1",
          "::ffff:240.0.0.1"
        ] do
      bracketed_host = if String.contains?(host, ":"), do: "[#{host}]", else: host

      assert {:ok, _setting} =
               Settings.put(
                 "providers.openai.base_url",
                 "http://#{bracketed_host}:11434/v1",
                 attach_ready(%{audit?: false})
               )

      assert {:ok, denied} = DoctorModelProfile.run(%{profile: "fast"}, %{})
      assert denied.status == :completed
      assert denied.doctor.endpoint_ok == false
      assert [%{code: :provider_host_denied}] = denied.doctor.diagnostics
    end

    for host <- ["::ffff:8.8.8.8", "2001:4860:4860::8888"] do
      assert {:ok, _setting} =
               Settings.put(
                 "providers.openai.base_url",
                 "https://[#{host}]/v1",
                 attach_ready(%{audit?: false})
               )

      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.host == host
        assert conn.request_path == "/v1/models"
        Req.Test.json(conn, %{"data" => []})
      end)

      assert {:ok, allowed} =
               DoctorModelProfile.run(
                 %{profile: "fast"},
                 attach_ready(%{req_options: [plug: {Req.Test, __MODULE__}]})
               )

      assert allowed.status == :completed
      assert allowed.doctor.endpoint_ok
    end
  end

  test "model doctor completes with redacted diagnostics for invalid OLLAMA_BASE_URL" do
    System.put_env("OLLAMA_BASE_URL", "not-a-valid-provider-url")

    assert {:ok, invalid} =
             DoctorModelProfile.run(%{profile: "direct_answer_local"}, %{})

    assert invalid.status == :completed
    assert invalid.profile == "direct_answer_local"
    assert invalid.provider == "local_ollama"
    assert invalid.model == "qwen2.5:7b"
    assert invalid.doctor.endpoint_kind == :local_endpoint
    assert invalid.doctor.redacted_host == "unknown"
    assert invalid.doctor.endpoint_ok == false
    assert [%{code: :invalid_provider_base_url}] = invalid.doctor.diagnostics
    refute inspect(invalid) =~ "not-a-valid-provider-url"
  end

  test "model doctor completes with redacted diagnostics for a nonloopback Ollama override" do
    System.put_env("OLLAMA_BASE_URL", "https://models.example.test/v1")

    assert {:ok, denied} =
             DoctorModelProfile.run(%{profile: "direct_answer_local"}, %{})

    assert denied.status == :completed
    assert denied.profile == "direct_answer_local"
    assert denied.provider == "local_ollama"
    assert denied.model == "qwen2.5:7b"
    assert denied.doctor.endpoint_kind == :local_endpoint
    assert denied.doctor.redacted_host == "unknown"
    assert denied.doctor.endpoint_ok == false
    assert [%{code: :provider_host_denied}] = denied.doctor.diagnostics
    refute inspect(denied) =~ "models.example.test"
  end

  test "local openai-compatible doctor prefers the configured vault key without leaking it" do
    secret = "sk-openai-compatible-doctor-key"

    assert {:ok, _settings} =
             Settings.write_user_settings(
               %{
                 "providers" => %{"openai" => %{"type" => "openai_compatible"}}
               },
               [],
               ReadyEffectContext.context()
             )

    assert {:ok, _secret} =
             Settings.Secrets.put_secret(
               "secret://providers/openai/api_key",
               secret,
               ReadyEffectContext.attach(%{
                 actor: "local",
                 channel: :test
               })
             )

    System.put_env("OLLAMA_BASE_URL", "http://127.0.0.1:11434/v1")

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/models"
      assert {"authorization", "Bearer #{secret}"} in conn.req_headers
      refute {"authorization", "Bearer ollama"} in conn.req_headers

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(%{"data" => [%{"id" => "gpt-4o-mini"}]})
      )
    end)

    assert {:ok, doctor} =
             DoctorModelProfile.run(
               %{profile: "fast"},
               attach_ready(%{req_options: [plug: {Req.Test, __MODULE__}]})
             )

    assert doctor.status == :completed
    assert doctor.doctor.endpoint_kind == :credentialed_remote
    assert doctor.doctor.effective_endpoint_class == :local
    assert doctor.doctor.credential_ok == true
    assert doctor.doctor.endpoint_ok == true
    assert doctor.doctor.model_available == true
    assert doctor.doctor.diagnostics == []
    refute inspect(doctor) =~ secret
  end

  test "provider credential action gives explicit flow guidance and refuses raw prompt secrets" do
    assert {:ok, guidance} = SetProviderCredential.run(%{provider: "openai"}, %{})
    assert guidance.status == :completed
    assert guidance.message =~ "mix allbert.settings providers set-key openai"

    assert {:ok, refused} =
             SetProviderCredential.run(%{provider: "openai", mode: :raw_prompt_secret}, %{})

    assert refused.status == :denied
    assert refused.message =~ "will not store provider credentials"

    assert {:ok, denied_read} =
             SetProviderCredential.run(%{provider: "openai", mode: :raw_secret_read}, %{})

    assert denied_read.status == :denied
    assert denied_read.message =~ "cannot display raw provider secrets"
  end

  test "provider credential action stores explicit secret values without echoing them" do
    context = attach_ready(%{actor: "local", channel: :test})

    assert {:ok, response} =
             SetProviderCredential.run(
               %{provider: "openai", mode: :set_secret, api_key: "test-key"},
               context
             )

    assert response.status == :completed
    assert response.provider == "openai"
    assert response.credential_status == :configured
    assert response.message =~ "Provider credential saved"
    refute inspect(response) =~ "test-key"
    assert {:ok, "test-key"} = Settings.Secrets.get_secret("secret://providers/openai/api_key")
  end

  test "provider credential completion reconciles a newly callable hosted DirectAnswer route" do
    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.direct_answer",
               ["fast"],
               ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, _setting} =
             Settings.put(
               "intent.direct_answer_model_enabled",
               true,
               ReadyEffectContext.attach(%{audit?: false})
             )

    refute Disclosure.hosted_pending?(:cli)

    assert {:ok, response} =
             SetProviderCredential.run(
               %{provider: "openai", mode: :set_secret, api_key: "test-key"},
               attach_ready(%{actor: "local", channel: :cli})
             )

    assert response.status == :completed
    assert Disclosure.hosted_pending?(:cli)
    assert Disclosure.text(:cli) =~ "fast from openai"
    refute inspect(response) =~ "test-key"
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp attach_ready(context) do
    Map.merge(context, Process.get(@ready_context_key) || raise("missing ready effect context"))
  end

  defp operator_report_params do
    %{render_mode: "operator_report", surface: "cli", surface_policy_affordance: true}
  end
end
