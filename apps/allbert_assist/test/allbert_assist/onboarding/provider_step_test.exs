defmodule AllbertAssist.Onboarding.ProviderStepTest do
  @moduledoc """
  v0.63 M3 — the shared provider/model step logic: vault-tier surfacing, provider
  readiness (`:needs_credentials`), and inline-doctor interpretation. Masked-write
  redaction itself is covered by `SettingsActionsTest` (the action layer); here we
  verify the wizard-layer interpretation + one integration tie-in.
  """
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Settings.SetProviderCredential
  alias AllbertAssist.Onboarding.ProviderStep
  alias AllbertAssist.Settings

  describe "vault_tier_report/1 (injected)" do
    test "OS and encrypted tiers are writable; env tier is read-only" do
      os =
        ProviderStep.vault_tier_report(
          resolve: %{tier: :os, notice: "keychain"},
          env_provided: []
        )

      assert os.tier == :os
      assert os.writable?
      assert os.label =~ "keychain" or os.label =~ "OS"

      enc =
        ProviderStep.vault_tier_report(
          resolve: %{tier: :encrypted_file, notice: "file"},
          env_provided: []
        )

      assert enc.writable?

      env =
        ProviderStep.vault_tier_report(resolve: %{tier: :env, notice: "env"}, env_provided: [])

      refute env.writable?
      assert env.label =~ "read-only"
    end

    test "surfaces env-provided provider keys as read-only, never as a write target" do
      report =
        ProviderStep.vault_tier_report(
          resolve: %{tier: :os, notice: ""},
          env_provided: ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"]
        )

      assert report.env_provided == ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"]
      # The active write tier stays OS; env keys are surfaced, not written.
      assert report.writable?
    end
  end

  describe "credential_status/2" do
    test "a local endpoint needs no key and is ready" do
      s = ProviderStep.credential_status("local_ollama", endpoint_kind: :local_endpoint)
      refute s.needs_key?
      assert s.readiness == :ready
      assert s.source == :none
    end

    test "a hosted provider with no key is :needs_credentials" do
      s =
        ProviderStep.credential_status("openai",
          endpoint_kind: :credentialed_remote,
          key_present?: false
        )

      assert s.needs_key?
      assert s.readiness == :needs_credentials
      assert s.source == :none
    end

    test "a hosted provider with a key present is ready, tracking the source" do
      vault = ProviderStep.credential_status("openai", key_present?: true, key_source: :vault)
      assert vault.readiness == :ready
      assert vault.source == :vault

      env =
        ProviderStep.credential_status("anthropic",
          endpoint_kind: :credentialed_remote,
          key_present?: true,
          key_source: :env
        )

      assert env.readiness == :ready
      assert env.source == :env
    end
  end

  describe "interpret_doctor/1" do
    test "unreachable endpoint fails with a repair action" do
      r = ProviderStep.interpret_doctor(%{endpoint_ok: false})
      refute r.ok?
      assert r.next_action =~ ~r/\S/
    end

    test "rejected credential on a remote endpoint fails" do
      r =
        ProviderStep.interpret_doctor(%{
          endpoint_ok: true,
          endpoint_kind: :credentialed_remote,
          credential_ok: false
        })

      refute r.ok?
      assert r.next_action =~ "key"
    end

    test "reachable endpoint but missing model fails" do
      r =
        ProviderStep.interpret_doctor(%{
          endpoint_ok: true,
          endpoint_kind: :local_endpoint,
          model_available: false
        })

      refute r.ok?
    end

    test "a full pass is ok with no repair action" do
      r =
        ProviderStep.interpret_doctor(%{
          endpoint_ok: true,
          endpoint_kind: :credentialed_remote,
          credential_ok: true,
          model_available: true
        })

      assert r.ok?
      assert r.next_action == nil
    end

    test "inconclusive model listing is a soft pass" do
      r =
        ProviderStep.interpret_doctor(%{
          endpoint_ok: true,
          endpoint_kind: :local_endpoint,
          model_available: :unknown
        })

      assert r.ok?
    end
  end

  describe "integration: masked store + tier reflected" do
    setup do
      original = Application.get_env(:allbert_assist, Settings)

      root =
        Path.join(
          System.tmp_dir!(),
          "allbert-provider-step-#{System.unique_integer([:positive])}"
        )

      Application.put_env(:allbert_assist, Settings, root: root)

      on_exit(fn ->
        if original,
          do: Application.put_env(:allbert_assist, Settings, original),
          else: Application.delete_env(:allbert_assist, Settings)

        File.rm_rf!(root)
      end)

      :ok
    end

    test "storing a masked key never echoes it and leaves a retrievable ref; tier is reportable" do
      assert {:ok, response} =
               SetProviderCredential.run(
                 %{provider: "openai", mode: :set_secret, api_key: "sk-secret-xyz"},
                 %{actor: "local", channel: :test}
               )

      assert response.status == :completed
      refute inspect(response) =~ "sk-secret-xyz"

      assert {:ok, "sk-secret-xyz"} =
               Settings.Secrets.get_secret("secret://providers/openai/api_key")

      report = ProviderStep.vault_tier_report()
      assert report.tier in [:os, :encrypted_file, :env]
      assert is_binary(report.label)
    end
  end
end
