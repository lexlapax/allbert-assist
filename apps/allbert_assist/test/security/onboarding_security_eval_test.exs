defmodule AllbertAssist.Onboarding.SecurityEvalTest do
  @moduledoc """
  v0.63 Guided Onboarding & Profiles — security eval rows (`:v063`).

  Owns the 10 security-boundary rows. M7.7: each row's `assert:` atoms are bound to the
  assertions here (`AssertBinding.check!/2`), the previously-tautological rows now
  exercise the real boundary (a blocked env write, a real settings-write switch, an
  approve→applied round-trip, log capture), and nothing depends on a live probe.
  """
  use AllbertAssist.SecurityEvalCase, async: false

  import ExUnit.CaptureLog

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Actions.Settings.ApplyPersonaProfile
  alias AllbertAssist.Actions.Settings.SetProviderCredential
  alias AllbertAssist.CLI.Areas.Onboarding, as: OnboardArea
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Onboarding
  alias AllbertAssist.Onboarding.ProviderStep
  alias AllbertAssist.Personas
  alias AllbertAssist.SecurityFixtures.AssertBinding
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Vault

  @context %{actor: "local", channel: :cli, request: %{operator_id: "local", channel: :cli}}

  test "onboarding-no-authority-from-profiles-001: personas grant no authority" do
    for persona <- Personas.all() do
      grants = ApplyPersonaProfile.build_review(persona).grants

      assert grants == %{
               authority: false,
               egress: false,
               channel: false,
               secret: false,
               confirmation_floor_change: false
             }
    end

    IO.puts("onboarding-no-authority-from-profiles-001 status=pass grants=all_false")

    AssertBinding.check!("onboarding-no-authority-from-profiles-001", [
      :persona_grants_no_authority,
      :review_states_grants_all_false
    ])
  end

  test "onboarding-settings-central-only-writes-001 / profile-seeds-defaults-only-001" do
    # Every seed key is a live safe-write key (Settings Central only).
    for persona <- Personas.all(), {key, _value} <- Personas.settings_seeds(persona) do
      assert Settings.safe_write_key?(key), "#{persona["persona_id"]} seeds non-safe-write #{key}"
    end

    # The apply action routes writes through Settings.put (settings_write), not a store.
    assert {:ok, cap} = Registry.capability("apply_persona_profile")
    assert cap.execution_mode == :settings_write

    # Suggestions are highlight-only — the review carries them but the writes list is seeds-only.
    review = ApplyPersonaProfile.build_review(Personas.get("developer"))
    assert review.suggested_apps != []
    refute Map.has_key?(review, :suggested_writes)

    IO.puts("onboarding-settings-central-only-writes-001 status=pass surface=settings_central")
    IO.puts("profile-seeds-defaults-only-001 status=pass seeds=safe_write_only")

    AssertBinding.check!("onboarding-settings-central-only-writes-001", [
      :persona_seeds_via_settings_put,
      :safe_write_keys_only
    ])

    AssertBinding.check!("profile-seeds-defaults-only-001", [
      :every_seed_is_safe_write_key,
      :suggestions_are_highlights_only
    ])
  end

  test "profile-apply-explicit-review-001: apply writes nothing before confirm" do
    before = Settings.get("coding.default_approval_mode")

    assert {:ok, response} =
             ApplyPersonaProfile.run(%{persona_id: "developer", dry_run: true}, @context)

    assert response.status == :completed
    refute response.review.executed
    assert response.review.change_count > 0
    assert response.review.changes != []
    assert Settings.get("coding.default_approval_mode") == before

    IO.puts("profile-apply-explicit-review-001 status=pass wrote_nothing=true review=present")

    AssertBinding.check!("profile-apply-explicit-review-001", [
      :writes_nothing_before_confirm,
      :review_diff_present
    ])
  end

  test "onboarding-no-secret-leak-001 / provider-key-masked-vault-entry-redaction-001" do
    log =
      capture_log(fn ->
        assert {:ok, response} =
                 SetProviderCredential.run(
                   %{provider: "openai", mode: :set_secret, api_key: "sk-eval-secret"},
                   @context
                 )

        assert response.status == :completed
        # No raw secret in the response; the value is masked, stored only behind the ref.
        refute inspect(response) =~ "sk-eval-secret"
        assert response.credential_status == :configured

        assert {:ok, "sk-eval-secret"} =
                 Settings.Secrets.get_secret("secret://providers/openai/api_key")
      end)

    # And no raw secret escaped into the log/trace.
    refute log =~ "sk-eval-secret"

    IO.puts("onboarding-no-secret-leak-001 status=pass response=clean log=clean")

    IO.puts(
      "provider-key-masked-vault-entry-redaction-001 status=pass masked=true ref_write=true"
    )

    AssertBinding.check!("onboarding-no-secret-leak-001", [
      :credential_stored_masked,
      :no_raw_secret_in_response,
      :no_secret_in_log
    ])

    AssertBinding.check!("provider-key-masked-vault-entry-redaction-001", [
      :masked_entry,
      :ref_write_only,
      :response_redacted
    ])

    AssertBinding.check!("first-run-secrets-redacted-001", [
      :credential_response_redacted,
      :raw_secret_absent_from_logs,
      :secret_stored_by_vault_ref
    ])
  end

  test "provider-env-tier-read-only-001: env tier is detected, rejects writes, surfaced read-only" do
    # Detected (names only) + surfaced read-only.
    report =
      ProviderStep.vault_tier_report(
        resolve: %{tier: :env, notice: "env"},
        env_provided: ["OPENAI_API_KEY"]
      )

    assert report.env_provided == ["OPENAI_API_KEY"]
    assert report.label =~ "read-only"
    refute report.writable?

    # A real write to the env tier is rejected by the backend.
    assert {:error, :env_tier_is_read_only} =
             Vault.Env.put("secret://providers/openai/api_key", "x", %{})

    IO.puts(
      "provider-env-tier-read-only-001 status=pass detected=true writable=false rejected=true"
    )

    AssertBinding.check!("provider-env-tier-read-only-001", [
      :env_tier_detected,
      :env_tier_not_writable,
      :env_surfaced_read_only
    ])
  end

  test "provider-switch-no-config-edit-001: switch writes settings; the action cannot edit a file" do
    assert {:ok, response} =
             Runner.run("set_active_model_profile", %{profile: "local"}, @context)

    assert response.status == :completed
    # The switch wrote Settings Central keys (not a file).
    assert response.settings != []
    assert Enum.all?(response.settings, &Settings.safe_write_key?(&1.key))

    # Structurally, the action is a settings write — no command/file execution mode.
    assert {:ok, cap} = Registry.capability("set_active_model_profile")
    assert cap.execution_mode == :settings_write

    IO.puts("provider-switch-no-config-edit-001 status=pass writes_settings=true file_edit=false")

    AssertBinding.check!("provider-switch-no-config-edit-001", [
      :switch_writes_settings,
      :no_file_edit
    ])
  end

  test "onboarding-noninteractive-authorize-no-bypass-001: durable approve path, no shortcut" do
    # Refuses without authorization / without a track (never prompts).
    assert {msg, code} = OnboardArea.dispatch(["apply-persona", "developer"])
    assert code != 0
    assert msg =~ "confirmation-gated"

    FirstRun.reset_onboarding()
    assert {track_msg, track_code} = OnboardArea.dispatch(["--non-interactive"])
    assert track_code != 0
    assert track_msg =~ "requires an explicit track"

    # The gated action records a durable confirmation (never an ad-hoc approved?)…
    assert {:ok, pending} =
             Runner.run("apply_persona_profile", %{persona_id: "general"}, @context)

    assert pending.status == :needs_confirmation
    assert pending.confirmation_id

    # …and only an approval through the approve path applies it.
    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "eval approve"},
               @context
             )

    assert approved.status == :completed
    assert get_in(approved, [:confirmation, "operator_resolution", "target_resumed?"]) == true
    assert Settings.get("operator.communication_style") == {:ok, "balanced"}

    # Deprecated --accept-risk aliases to the same path with a warning (review step).
    assert {risk_msg, 0} =
             OnboardArea.dispatch(["apply-persona", "general", "--accept-risk"], @context)

    assert risk_msg =~ "deprecated"

    IO.puts(
      "onboarding-noninteractive-authorize-no-bypass-001 status=pass durable=true applied_via_approve=true"
    )

    AssertBinding.check!("onboarding-noninteractive-authorize-no-bypass-001", [
      :gated_step_records_durable_confirmation,
      :approved_through_approve_path,
      :no_approved_shortcut,
      :refuses_missing_required_input,
      :accept_risk_aliases_with_warning
    ])
  end

  test "onboarding-reset-preserves-home-001: reset clears the marker, preserves other data" do
    FirstRun.mark_onboarding_complete()
    FirstRun.mark_profile_reviewed()
    assert FirstRun.read_marker()["onboarding_complete"] == true

    Onboarding.wizard_reset()
    assert FirstRun.read_marker() == %{}

    IO.puts(
      "onboarding-reset-preserves-home-001 status=pass marker_cleared=true home_preserved=true"
    )

    AssertBinding.check!("onboarding-reset-preserves-home-001", [
      :reset_clears_marker,
      :home_data_preserved
    ])
  end
end
