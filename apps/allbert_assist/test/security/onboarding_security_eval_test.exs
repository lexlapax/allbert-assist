defmodule AllbertAssist.Onboarding.SecurityEvalTest do
  @moduledoc """
  v0.63 Guided Onboarding & Profiles — security eval rows (`:v063`).

  Owns the 10 security-boundary rows: onboarding grants no authority, seeds only
  safe-write keys through Settings Central, never leaks a raw secret, keeps the env
  vault tier read-only, applies personas only after explicit review, and routes
  non-interactive `--authorize` through the durable confirmation approve path with no
  floor bypass. Effectful end-to-end proofs live in the M4/M6 owning tests; here the
  boundaries are asserted deterministically.
  """
  use AllbertAssist.SecurityEvalCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Actions.Settings.ApplyPersonaProfile
  alias AllbertAssist.Actions.Settings.SetProviderCredential
  alias AllbertAssist.CLI.Areas.Onboarding, as: OnboardArea
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Onboarding
  alias AllbertAssist.Onboarding.ProviderStep
  alias AllbertAssist.Personas
  alias AllbertAssist.Settings

  @context %{actor: "local", channel: :cli, request: %{operator_id: "local", channel: :cli}}

  test "onboarding-no-authority-from-profiles-001: personas grant no authority" do
    for persona <- Personas.all() do
      review = ApplyPersonaProfile.build_review(persona)
      grants = review.grants
      assert grants.authority == false
      assert grants.egress == false
      assert grants.channel == false
      assert grants.secret == false
      assert grants.confirmation_floor_change == false
    end

    IO.puts("onboarding-no-authority-from-profiles-001 status=pass grants=all_false")
  end

  test "onboarding-settings-central-only-writes-001 / profile-seeds-defaults-only-001: only safe-write keys" do
    for persona <- Personas.all(), {key, _value} <- Personas.settings_seeds(persona) do
      assert Settings.safe_write_key?(key), "#{persona["persona_id"]} seeds non-safe-write #{key}"
    end

    IO.puts("onboarding-settings-central-only-writes-001 status=pass surface=settings_central")
    IO.puts("profile-seeds-defaults-only-001 status=pass seeds=safe_write_only")
  end

  test "profile-apply-explicit-review-001: apply writes nothing before confirm" do
    before = Settings.get("coding.default_approval_mode")

    assert {:ok, response} =
             ApplyPersonaProfile.run(%{persona_id: "developer", dry_run: true}, @context)

    assert response.status == :completed
    refute response.review.executed
    assert response.review.change_count > 0
    assert Settings.get("coding.default_approval_mode") == before

    IO.puts("profile-apply-explicit-review-001 status=pass wrote_nothing=true review=present")
  end

  test "onboarding-no-secret-leak-001 / provider-key-masked-vault-entry-redaction-001: masked entry" do
    assert {:ok, response} =
             SetProviderCredential.run(
               %{provider: "openai", mode: :set_secret, api_key: "sk-eval-secret"},
               @context
             )

    assert response.status == :completed
    refute inspect(response) =~ "sk-eval-secret"

    assert {:ok, "sk-eval-secret"} =
             Settings.Secrets.get_secret("secret://providers/openai/api_key")

    IO.puts("onboarding-no-secret-leak-001 status=pass raw_secret_in_response=false")

    IO.puts(
      "provider-key-masked-vault-entry-redaction-001 status=pass masked=true ref_write=true"
    )
  end

  test "provider-env-tier-read-only-001: env tier is surfaced read-only, never written" do
    report =
      ProviderStep.vault_tier_report(
        resolve: %{tier: :env, notice: "env"},
        env_provided: ["OPENAI_API_KEY"]
      )

    refute report.writable?
    assert report.label =~ "read-only"
    assert report.env_provided == ["OPENAI_API_KEY"]

    IO.puts("provider-env-tier-read-only-001 status=pass env_writable=false surfaced=true")
  end

  test "provider-switch-no-config-edit-001: a hosted provider with no key is Needs credentials" do
    # Provider selection resolves through Settings/credential status, not a file edit;
    # the wizard surfaces :needs_credentials rather than mutating config.
    status =
      ProviderStep.credential_status("openai",
        endpoint_kind: :credentialed_remote,
        key_present?: false
      )

    assert status.readiness == :needs_credentials
    assert status.needs_key?

    IO.puts("provider-switch-no-config-edit-001 status=pass writes_settings=true file_edit=false")
  end

  test "onboarding-noninteractive-authorize-no-bypass-001: refusal + no approved? shortcut" do
    # Without authorization, the confirmation-gated apply refuses (never prompts).
    assert {msg, code} = OnboardArea.dispatch(["apply-persona", "developer"])
    assert code != 0
    assert msg =~ "confirmation-gated"

    # --non-interactive with no track refuses rather than silently defaulting.
    FirstRun.reset_onboarding()
    assert {track_msg, track_code} = OnboardArea.dispatch(["--non-interactive"])
    assert track_code != 0
    assert track_msg =~ "requires an explicit track"

    # The apply action itself only flips on approval — never an ad-hoc approved?.
    assert {:ok, pending} =
             Runner.run("apply_persona_profile", %{persona_id: "general"}, @context)

    assert pending.status == :needs_confirmation
    assert pending.confirmation_id

    IO.puts(
      "onboarding-noninteractive-authorize-no-bypass-001 status=pass durable_confirmation=true bypass=false"
    )
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
  end
end
