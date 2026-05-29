defmodule AllbertAssist.Actions.SettingsActionsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Settings.DoctorModelProfile
  alias AllbertAssist.Actions.Settings.ExplainSetting
  alias AllbertAssist.Actions.Settings.ListModelProfiles
  alias AllbertAssist.Actions.Settings.ListProviderProfiles
  alias AllbertAssist.Actions.Settings.ListSettings
  alias AllbertAssist.Actions.Settings.ReadSetting
  alias AllbertAssist.Actions.Settings.SetActiveModelProfile
  alias AllbertAssist.Actions.Settings.SetProviderCredential
  alias AllbertAssist.Actions.Settings.UpdateSetting
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.DoctorDiagnostics

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-settings-actions-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "list/read/explain settings actions return settings metadata" do
    assert {:ok, list_response} = ListSettings.run(%{}, %{})
    assert list_response.status == :completed
    assert list_response.message =~ "operator.timezone"
    assert list_response.message =~ "model_profiles.fast.max_tokens: 1024"
    assert list_response.message =~ "providers.openai.api_key_ref: \"[REDACTED]\""
    assert Enum.any?(list_response.settings, &(&1.key == "operator.timezone"))
    assert [%{name: "list_settings", settings_metadata: %{count: count}}] = list_response.actions
    assert count > 0

    assert {:ok, read_response} = ReadSetting.run(%{key: "operator.timezone"}, %{})
    assert read_response.status == :completed
    assert read_response.message =~ "America/Los_Angeles"
    assert read_response.setting.key == "operator.timezone"

    assert {:ok, explain_response} = ExplainSetting.run(%{key: "operator.timezone"}, %{})
    assert explain_response.status == :completed
    assert explain_response.message =~ "Layers:"
    assert explain_response.setting.layers != []
  end

  test "update setting writes safe key and rejects read-only key" do
    context = %{request: %{operator_id: "local", channel: :test, input_signal_id: "sig"}}

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
    context = %{request: %{operator_id: "local", channel: :test, input_signal_id: "sig"}}

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
    assert response.message =~ "endpoint_kind=credentialed_remote"
    assert response.message =~ "credential=missing"
    assert Enum.any?(response.providers, &(&1.name == "openai"))
    refute response.message =~ "api_key"
  end

  test "model profile action returns only redacted credential status" do
    assert {:ok, response} = ListModelProfiles.run(%{}, %{})

    assert response.status == :completed
    assert response.message =~ "endpoint_kind=local_endpoint"
    assert response.message =~ "credential=missing"
    assert Enum.any?(response.models, &(&1.name == "fast"))
    refute response.message =~ "api_key"
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
             SetActiveModelProfile.run(%{profile: "local", enable_assist: true}, %{
               actor: "local",
               channel: :test
             })

    assert set_active.status == :completed
    assert set_active.provider == "local_ollama"
    assert {:ok, "local"} = Settings.get("intent.model_profile")
    assert {:ok, true} = Settings.get("intent.model_assist_enabled")
    assert {:ok, true} = Settings.get("providers.local_ollama.enabled")
    assert Enum.any?(set_active.settings, &(&1.key == "intent.model_profile"))
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

    context = %{req_options: [plug: {Req.Test, __MODULE__}]}

    assert {:ok, missing} = DoctorModelProfile.run(%{profile: "local"}, context)
    assert missing.status == :completed
    assert missing.doctor.endpoint_kind == :local_endpoint
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
               %{
                 actor: "local",
                 channel: :test
               }
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
             DoctorModelProfile.run(%{profile: "anthropic_fast"}, %{
               req_options: [plug: {Req.Test, __MODULE__}]
             })

    assert doctor.status == :completed
    assert doctor.doctor.endpoint_kind == :credentialed_remote
    assert doctor.doctor.credential_ok
    assert doctor.doctor.endpoint_ok
    assert doctor.doctor.model_available == true
    assert doctor.doctor.context_window == 200_000
    refute inspect(doctor) =~ "sk-ant-test-key"
  end

  test "credentialed remote doctor resolves catalog aliases against provider model ids" do
    assert {:ok, _setting} =
             Settings.put("model_profiles.anthropic_fast.model", "claude-haiku-4-5", %{
               audit?: false
             })

    assert {:ok, _secret} =
             Settings.Secrets.put_secret(
               "secret://providers/anthropic/api_key",
               "sk-ant-test-key",
               %{actor: "local", channel: :test}
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
             DoctorModelProfile.run(%{profile: "anthropic_fast"}, %{
               req_options: [plug: {Req.Test, __MODULE__}]
             })

    assert doctor.doctor.model_available == true
    assert doctor.doctor.diagnostics == []
  end

  test "credentialed remote doctor supports Gemini model catalog without leaking secrets" do
    assert {:ok, _secret} =
             Settings.Secrets.put_secret(
               "secret://providers/gemini/api_key",
               "AIza-test-key",
               %{actor: "local", channel: :test}
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
             DoctorModelProfile.run(%{profile: "coding"}, %{
               req_options: [plug: {Req.Test, __MODULE__}]
             })

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
             Settings.put("providers.openai.base_url", "http://127.0.0.1:11434/v1", %{
               audit?: false
             })

    assert {:ok, _secret} =
             Settings.Secrets.put_secret(
               "secret://providers/openai/api_key",
               "sk-test-private",
               %{
                 actor: "local",
                 channel: :test
               }
             )

    assert {:ok, denied} = DoctorModelProfile.run(%{profile: "fast"}, %{})
    assert denied.status == :completed
    assert denied.doctor.endpoint_ok == false
    assert [%{code: :provider_host_denied}] = denied.doctor.diagnostics
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
    context = %{actor: "local", channel: :test}

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

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
