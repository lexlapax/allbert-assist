defmodule AllbertAssist.CLI.Areas.Onboarding do
  @moduledoc """
  Release-safe `onboard` dispatch (v0.63 M1) — the new top-level `allbert onboard`
  verb (Locked Decisions 2/7) and its `mix allbert.onboard` twin.

  `dispatch/2` parses the sub-argv/flags with `OptionParser` and drives the shared
  wizard state machine in `AllbertAssist.Onboarding` (the authoritative M1 API),
  returning `{rendered_output, exit_code}` — no `Mix.*` calls, so it runs inside
  the packaged release. Operator copy uses readiness labels, never raw probe atoms.

  M1 wires the flow + persistence; M6 adds the terminal `--authorize`
  pre-authorization (routes each confirmation-gated onboarding action — e.g.
  `apply_persona_profile` — through the durable confirmation *create + approve* path,
  never a floor bypass) and the non-interactive required-input refusal contract.
  """

  alias AllbertAssist.Actions.Runner
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
    allbert onboard apply-persona ID    # apply a persona (needs --authorize)
    allbert onboard trust               # the trust spine: what keeps first-run safe
    allbert onboard --reset --yes       # reset onboarding (marker only; Home preserved)

  Flags:
    --non-interactive --authorize       # automation: pre-authorizes gated steps by
                                        # creating + approving a durable confirmation
                                        # (never bypasses the floor). Refuses on any
                                        # missing required input.
  """

  @switches [
    quickstart: :boolean,
    advanced: :boolean,
    reset: :boolean,
    yes: :boolean,
    non_interactive: :boolean,
    authorize: :boolean,
    # Deprecated compatibility alias for --authorize; warns and routes to the same
    # durable approval path (Non-Interactive Authorization & Input Contract).
    accept_risk: :boolean,
    profile: :string,
    provider: :string,
    model: :string,
    endpoint: :string,
    key_ref: :string
  ]

  @readiness_copy %{
    ready: "Ready",
    needs_model: "Needs model",
    needs_runtime: "Needs runtime",
    needs_review: "Needs review",
    needs_credentials: "Needs credentials"
  }

  @spec dispatch([String.t()], map() | nil) :: {String.t(), non_neg_integer()}
  def dispatch(argv, context \\ nil) do
    # M7.6: one-time first-launch reconcile of a stale v0.62 onboarding objective
    # (marker-guarded, best-effort — no-op after the first onboard invocation).
    Onboarding.reconcile_stale_objective()
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    result =
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
          route(rest, opts, context)
      end

    maybe_warn_ignored_authorize(result, opts, rest)
  end

  # M7.1: `--authorize`/`--accept-risk` is consumed only by `apply-persona`; warn on a
  # typo like `onboard advance foo --authorize` rather than silently ignoring it.
  defp maybe_warn_ignored_authorize({out, code}, opts, rest) do
    auth? = opts[:authorize] == true or opts[:accept_risk] == true
    consumed? = match?(["apply-persona" | _], rest)

    if auth? and not consumed? do
      {"Warning: --authorize/--accept-risk has no effect here (only `apply-persona` uses it).\n" <>
         out, code}
    else
      {out, code}
    end
  end

  defp route([], opts, _context) do
    # v0.63 M6: non-interactive automation must not silently default a track — refuse
    # when starting fresh without one (Non-Interactive Authorization & Input Contract).
    state = Onboarding.wizard_resume()

    if opts[:non_interactive] and not state.started? do
      Render.error([
        "Refusing: --non-interactive requires an explicit track for a fresh onboarding.",
        "Supply --quickstart or --advanced."
      ])
    else
      render_state(state, nil)
    end
  end

  defp route(["status"], _opts, _context), do: {status_line(Onboarding.wizard_status()), 0}

  defp route(["advance", step], _opts, _context) do
    case Onboarding.wizard_advance(step) do
      {:ok, state} ->
        render_state(state, "Recorded #{step}.")

      {:error, {:not_current_step, current}} ->
        Render.error("Not the current step; current is #{current}.")

      {:error, {:unknown_step, s}} ->
        Render.error("Unknown step: #{s}.")
    end
  end

  defp route(["apply-persona", persona_id], opts, context),
    do: apply_persona(persona_id, opts, context)

  defp route(["apply-persona"], opts, context),
    do: apply_persona(opts[:profile], opts, context)

  defp route(["trust"], _opts, _context) do
    lines = [
      "The trust spine — what keeps first-run safe:"
      | Enum.map(Onboarding.trust_spine(), &("- " <> &1))
    ]

    Render.ok(lines)
  end

  defp route(_other, _opts, _context), do: Render.usage([@usage])

  # v0.63 M6: apply a persona through the durable pre-authorization path. The apply
  # action is confirmation-gated; --authorize (or the deprecated --accept-risk alias)
  # records + approves the confirmation. Without authorization we refuse rather than
  # prompt in an automation context.
  defp apply_persona(nil, _opts, _context),
    do: Render.error("apply-persona requires a persona id (or --profile ID).")

  defp apply_persona(persona_id, opts, context) do
    cond do
      not authorized?(opts) ->
        Render.error([
          "Applying persona '#{persona_id}' is confirmation-gated.",
          "Re-run with --authorize to review it, then --authorize --yes to apply."
        ])

      # M7.4: two-step — `--authorize` shows the review diff and writes nothing;
      # only `--authorize --yes` runs the durable create+approve path.
      opts[:yes] != true ->
        render_persona_review(persona_id, context, accept_risk_notice(opts))

      true ->
        deprecation = accept_risk_notice(opts)

        case run_authorized(
               "apply_persona_profile",
               %{persona_id: persona_id},
               context,
               deprecation
             ) do
          {_out, 0} = ok ->
            Onboarding.record_applied_persona(persona_id)
            ok

          other ->
            other
        end
    end
  end

  defp render_persona_review(persona_id, context, notices) do
    case Runner.run(
           "apply_persona_profile",
           %{persona_id: persona_id, dry_run: true},
           context || %{}
         ) do
      {:ok, %{status: :completed, review: review}} ->
        Render.ok(
          notices ++ persona_review_lines(review) ++ ["Re-run with `--authorize --yes` to apply."]
        )

      {:ok, response} ->
        Render.error(
          "Cannot review persona '#{persona_id}': #{inspect(Map.get(response, :status))}."
        )
    end
  end

  defp persona_review_lines(review) do
    header =
      "Review — #{review.persona_id} (#{review.change_count} change(s)); nothing is written until you apply:"

    [
      header
      | Enum.map(review.changes, fn c ->
          "  #{c.key}: #{inspect(c.current)} → #{inspect(c.proposed)}"
        end)
    ]
  end

  defp authorized?(opts), do: opts[:authorize] == true or opts[:accept_risk] == true

  defp accept_risk_notice(opts) do
    if opts[:accept_risk] == true and opts[:authorize] != true do
      ["Warning: --accept-risk is deprecated; use --authorize (same durable approval path)."]
    else
      []
    end
  end

  # Route a confirmation-gated action through the *create + approve* path: run it (it
  # returns :needs_confirmation with a durable record), then approve that record. Never
  # sets `approved?` ad hoc; never skips the floor.
  defp run_authorized(action, params, context, notices) do
    ctx = context || %{}

    case Runner.run(action, params, ctx) do
      {:ok, %{status: :needs_confirmation, confirmation_id: id}} ->
        approve_gated(action, id, ctx, notices)

      # M7.1: a confirmation-gated action must never complete without a confirmation.
      # An unexpected `:completed` on the create call means the floor was skipped —
      # refuse rather than report success.
      {:ok, %{status: :completed}} ->
        Render.error(
          notices ++
            ["Refusing: #{action} completed without a confirmation — the gate was not applied."]
        )

      {:ok, response} ->
        Render.error(
          notices ++ ["#{action} did not complete: #{inspect(Map.get(response, :status))}."]
        )
    end
  end

  defp approve_gated(action, confirmation_id, context, notices) do
    case Runner.run(
           "approve_confirmation",
           %{id: confirmation_id, reason: "allbert onboard --authorize"},
           context
         ) do
      {:ok, %{status: :completed}} ->
        Render.ok(
          notices ++
            [
              "Authorized and applied #{action} (durable confirmation #{confirmation_id} approved)."
            ]
        )

      {:ok, response} ->
        Render.error(
          notices ++ ["Approval did not complete: #{inspect(Map.get(response, :status))}."]
        )
    end
  end

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
        ] ++ guidance_lines(state) ++ first_chat_lines(state)

    Render.ok(Enum.reject(lines, &is_nil/1))
  end

  # M7.4: at the first_chat step (or once complete) surface the applied persona's
  # starter prompts so the operator reaches a first useful chat.
  defp first_chat_lines(state) do
    if state.step == "first_chat" or state.complete? do
      case Onboarding.first_chat_prompts() do
        [] -> []
        prompts -> ["", "Try a first chat:" | Enum.map(prompts, &("  - " <> &1))]
      end
    else
      []
    end
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
  # and any provider keys already provided by the environment (read-only, M3). M7.1:
  # the storage line is gated on `writable?` — the env tier rejects writes, so we must
  # not claim new keys land there.
  defp tier_lines("model_path") do
    report = ProviderStep.vault_tier_report()

    base =
      if report.writable? do
        ["New provider keys are stored in: #{report.label}."]
      else
        [
          "This tier (#{report.label}) can't store new keys; set a provider key in the environment, or enable the OS/encrypted vault."
        ]
      end

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
