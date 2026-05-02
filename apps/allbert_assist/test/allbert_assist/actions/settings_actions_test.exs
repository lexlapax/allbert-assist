defmodule AllbertAssist.Actions.SettingsActionsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Settings.ExplainSetting
  alias AllbertAssist.Actions.Settings.ListModelProfiles
  alias AllbertAssist.Actions.Settings.ListProviderProfiles
  alias AllbertAssist.Actions.Settings.ListSettings
  alias AllbertAssist.Actions.Settings.ReadSetting
  alias AllbertAssist.Actions.Settings.SetProviderCredential
  alias AllbertAssist.Actions.Settings.UpdateSetting
  alias AllbertAssist.Settings

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

  test "provider profile action returns only redacted credential status" do
    assert {:ok, response} = ListProviderProfiles.run(%{}, %{})

    assert response.status == :completed
    assert response.message =~ "credential=missing"
    assert Enum.any?(response.providers, &(&1.name == "openai"))
    refute response.message =~ "api_key"
  end

  test "model profile action returns only redacted credential status" do
    assert {:ok, response} = ListModelProfiles.run(%{}, %{})

    assert response.status == :completed
    assert response.message =~ "credential=missing"
    assert Enum.any?(response.models, &(&1.name == "fast"))
    refute response.message =~ "api_key"
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
