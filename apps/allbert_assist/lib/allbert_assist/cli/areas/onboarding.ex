defmodule AllbertAssist.CLI.Areas.Onboarding do
  @moduledoc """
  Release-safe `onboard` dispatch (v0.63 M1) — the new top-level `allbert onboard`
  verb (Locked Decisions 2/7) and its `mix allbert.onboard` twin.

  `dispatch/2` parses the sub-argv/flags with `OptionParser` and drives the shared
  wizard state machine in `AllbertAssist.Onboarding` (the authoritative M1 API),
  returning `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs inside
  the packaged release. Operator copy uses readiness labels, never raw probe atoms.

  M1 wires the flow + persistence; the per-step effectful actions (guided model
  setup, persona apply) and the `--authorize` pre-authorization land in M2–M4/M6.
  """

  alias AllbertAssist.CLI.Areas.Render
  alias AllbertAssist.Onboarding
  alias AllbertAssist.Onboarding.ProviderStep

  @usage """
  Usage:
    allbert onboard                     # resume (or show) the guided wizard
    allbert onboard --quickstart        # start the QuickStart track
    allbert onboard --advanced          # start the Advanced track
    allbert onboard status              # compact wizard status
    allbert onboard advance STEP        # record the current step done (automation)
    allbert onboard --reset --yes       # reset onboarding (marker only; Home preserved)

  Flags:
    --non-interactive --authorize       # automation (pre-authorizes gated steps
                                        # via the confirmation approve path; M2+)
  """

  @switches [
    quickstart: :boolean,
    advanced: :boolean,
    reset: :boolean,
    yes: :boolean,
    non_interactive: :boolean,
    authorize: :boolean
  ]

  @readiness_copy %{
    ready: "Ready",
    needs_model: "Needs model",
    needs_runtime: "Needs runtime",
    needs_review: "Needs review",
    needs_credentials: "Needs credentials"
  }

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, _context \\ nil) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    cond do
      invalid != [] ->
        Render.usage(["Unknown flag(s): #{inspect(Enum.map(invalid, &elem(&1, 0)))}", @usage])

      opts[:reset] ->
        reset(opts)

      opts[:quickstart] ->
        render_state(Onboarding.wizard_start(:quickstart), "Started QuickStart.")

      opts[:advanced] ->
        render_state(Onboarding.wizard_start(:advanced), "Started Advanced.")

      true ->
        route(rest)
    end
  end

  defp route([]), do: render_state(Onboarding.wizard_resume(), nil)
  defp route(["status"]), do: {status_line(Onboarding.wizard_status()), 0}

  defp route(["advance", step]) do
    case Onboarding.wizard_advance(step) do
      {:ok, state} ->
        render_state(state, "Recorded #{step}.")

      {:error, {:not_current_step, current}} ->
        Render.error("Not the current step; current is #{current}.")

      {:error, {:unknown_step, s}} ->
        Render.error("Unknown step: #{s}.")
    end
  end

  defp route(_other), do: Render.usage([@usage])

  defp reset(opts) do
    if opts[:yes] do
      state = Onboarding.wizard_reset()
      render_state(state, "Onboarding reset (marker cleared; Allbert Home preserved).")
    else
      Render.error([
        "Reset clears onboarding + profile-review + wizard progress (Home data is preserved).",
        "Re-run with `--reset --yes` to confirm."
      ])
    end
  end

  defp render_state(state, notice) do
    lines =
      [notice] ++
        [
          "Wizard: #{if state.started?, do: "in progress", else: "not started"} (track: #{state.track})",
          "Step: #{state.step}",
          "Readiness: #{Map.get(@readiness_copy, state.readiness, "Unknown")}",
          "Profile reviewed: #{state.profile_reviewed?}",
          "Onboarding complete: #{state.complete?}"
        ] ++ guidance_lines(state)

    Render.ok(Enum.reject(lines, &is_nil/1))
  end

  # At the model_path step (or whenever the model isn't ready yet), surface the
  # single next action in operator language — the M2 no-dead-end guarantee.
  defp guidance_lines(state) do
    if state.step == "model_path" or state.readiness != :ready do
      g = Onboarding.model_guidance_for(state.readiness, state.track)
      [""] ++ [g.headline, "Next: #{g.next_action}"] ++ tier_lines(state.step)
    else
      []
    end
  end

  # At the model/provider step, show where a new masked credential would be stored
  # and any provider keys already provided by the environment (read-only, M3).
  defp tier_lines("model_path") do
    report = ProviderStep.vault_tier_report()

    base = ["New provider keys are stored in: #{report.label}."]

    case report.env_provided do
      [] -> base
      keys -> base ++ ["Provided by environment (read-only): #{Enum.join(keys, ", ")}."]
    end
  rescue
    _error -> []
  end

  defp tier_lines(_step), do: []

  defp status_line(status) do
    "onboard status=#{if status.complete?, do: "complete", else: "in_progress"} " <>
      "track=#{status.track} step=#{status.step} " <>
      "readiness=#{Map.get(@readiness_copy, status.readiness, "unknown")} " <>
      "profile_reviewed=#{status.profile_reviewed?}\n"
  end
end
