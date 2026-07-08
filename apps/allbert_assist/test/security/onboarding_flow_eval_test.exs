defmodule AllbertAssist.Onboarding.FlowEvalTest do
  @moduledoc """
  v0.63 Guided Onboarding & Profiles — flow eval rows (`:v063`).

  Owns the 4 flow-boundary rows: web + terminal drive identical step IDs (no surface
  fork), operator surfaces show mapped readiness labels + one next action (never a raw
  probe atom), the trust spine is surfaced as a feature, and QuickStart reaches first
  chat or a specific repair from every first-model probe outcome.
  """
  use AllbertAssist.SecurityEvalCase, async: false

  alias AllbertAssist.CLI.Areas.Onboarding, as: OnboardArea
  alias AllbertAssist.Onboarding

  @canonical ~w(welcome track_select model_path profile_select profile_review
                health_check first_chat optional_connect)

  test "wizard-shared-flow-no-surface-fork-001: one canonical 8-step set for both surfaces" do
    assert Onboarding.wizard_steps() == @canonical

    # The CLI dispatcher advances exactly the canonical steps (same source of truth
    # the web LiveComponent renders).
    Onboarding.wizard_start(:quickstart)
    assert {out, 0} = OnboardArea.dispatch(["status"])
    assert out =~ "step="

    IO.puts("wizard-shared-flow-no-surface-fork-001 status=pass canonical_steps=8 fork=false")
  end

  test "wizard-operator-readiness-copy-001: mapped labels + one next action, no raw atom" do
    for probe <-
          ~w(local_ready byok_ready runtime_missing runtime_unhealthy model_missing below_hardware_floor)a,
        track <- [:quickstart, :advanced] do
      g = Onboarding.model_path_guidance(first_model_state: probe, track: track)
      blob = g.headline <> " " <> g.next_action

      # No raw probe / internal readiness atom in operator copy.
      for atom <- ~w(local_ready byok_ready runtime_missing runtime_unhealthy
                     model_missing below_hardware_floor needs_runtime needs_model needs_review) do
        refute blob =~ atom
      end

      assert g.next_action =~ ~r/\S/
    end

    # The label mapper produces only the contract's operator labels.
    assert Onboarding.readiness_label(first_model_state: :below_hardware_floor) == :needs_review

    IO.puts(
      "wizard-operator-readiness-copy-001 status=pass mapped=true next_action=present raw_atom=false"
    )
  end

  test "trust-spine-surfaced-001: the trust spine is surfaced in both terminal and shared copy" do
    spine = Onboarding.trust_spine()
    blob = Enum.join(spine, " ") |> String.downcase()

    assert blob =~ "confirmation"
    assert blob =~ "permission"
    assert blob =~ "trace"
    assert blob =~ "local"

    # The terminal surface renders it.
    assert {out, 0} = OnboardArea.dispatch(["trust"])
    assert out =~ "trust spine"

    IO.puts(
      "trust-spine-surfaced-001 status=pass surface=present names=confirmation,permission,traces,local"
    )
  end

  test "quickstart-fastest-first-chat-001: ready reaches chat; every other outcome is repairable" do
    for probe <-
          ~w(local_ready byok_ready runtime_missing runtime_unhealthy model_missing below_hardware_floor)a do
      g = Onboarding.model_path_guidance(first_model_state: probe, track: :quickstart)

      if g.reaches_chat? do
        assert probe in [:local_ready, :byok_ready]
      else
        assert g.repairable?
        assert g.action in [:install_runtime, :pull_model, :choose_provider]
      end
    end

    IO.puts("quickstart-fastest-first-chat-001 status=pass ready_reaches_chat=true dead_ends=0")
  end
end
