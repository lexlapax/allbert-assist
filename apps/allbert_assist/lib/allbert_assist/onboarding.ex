defmodule AllbertAssist.Onboarding do
  @moduledoc """
  First-run onboarding — the authoritative guided-wizard state machine.

  v0.63 M7.3: the legacy objective-backed onboarding flow (`frame_or_resume`/
  `complete_step`/step tables) is retired; the wizard machine over the FirstRun Home
  marker (`<Home>/onboarding.json`) is the sole onboarding source and surface. The
  only objective coupling that remains is `cancel_active_objective/1`, used by
  `wizard_reset/1` and the one-time `reconcile_stale_objective/1` to cancel a stale
  in-flight v0.62 onboarding objective; `@source_intent` identifies it.
  """

  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Personas

  @source_intent "first_run_onboarding"
  # v0.63 M1: the authoritative guided-wizard state machine.
  #
  # The 8 canonical step IDs (design `onboarding-flow.md`), two tracks, and a
  # single "onboarding complete" source of truth — the FirstRun Home marker
  # (`<Home>/onboarding.json`), Locked Decision 1. Wizard progress (track,
  # current step, completed steps) is persisted in the same marker. The legacy
  # objective flow above is retained as durable trace and back-compat for the
  # not-yet-migrated web panel; it retires as the surfaces migrate (M5/M6/M7).
  # This module is surface-agnostic: web (M5) and terminal (M6) render it.
  # ==========================================================================

  @wizard_steps ~w(welcome track_select model_path profile_select profile_review
                   health_check first_chat optional_connect)
  @wizard_tracks [:quickstart, :advanced]

  @typedoc "A guided-wizard step id."
  @type wizard_step :: String.t()
  @typedoc "A wizard track."
  @type track :: :quickstart | :advanced
  @typedoc """
  Operator readiness label per the Readiness Label Mapping Contract. The model probe
  yields `:ready`/`:needs_runtime`/`:needs_model`/`:needs_review`; `:needs_credentials`
  is produced only by the provider step (hosted/BYOK chosen, no key present).
  """
  @type readiness ::
          :ready | :needs_model | :needs_runtime | :needs_review | :needs_credentials

  @typedoc "The readiness labels the model probe can yield (excludes `:needs_credentials`)."
  @type probe_readiness :: :ready | :needs_model | :needs_runtime | :needs_review

  @typedoc "The single next action the `model_path`/provider step should route to."
  @type model_action ::
          :start_chat | :install_runtime | :pull_model | :choose_provider | :enter_credentials

  @typedoc """
  Track-aware guidance for the `model_path` step: an operator-language headline +
  the single repair/next action. `reaches_chat?` is true only when the model is
  usable now; otherwise `repairable?` is always true (no dead ends — M2 invariant).
  """
  @type model_guidance :: %{
          readiness: readiness(),
          headline: String.t(),
          next_action: String.t(),
          action: model_action(),
          repairable?: boolean(),
          reaches_chat?: boolean()
        }

  @typedoc "The derived guided-wizard state."
  @type wizard :: %{
          started?: boolean(),
          track: track(),
          step: wizard_step(),
          done: [wizard_step()],
          next: wizard_step() | nil,
          readiness: readiness(),
          profile_reviewed?: boolean(),
          complete?: boolean(),
          detect: FirstRun.state()
        }

  @typedoc "Compact wizard status summary."
  @type wizard_status :: %{
          started?: boolean(),
          track: track(),
          step: wizard_step(),
          readiness: readiness(),
          complete?: boolean(),
          profile_reviewed?: boolean()
        }

  # v0.63 M7: the trust spine surfaced as a first-run feature — confirmation,
  # permission scoping, traces, and local inspectability are safety properties, not
  # setup friction. Onboarding itself grants no new authority. Shared copy for both
  # the terminal (`allbert onboard trust`) and web surfaces.
  @trust_spine [
    "Confirmation: risky actions pause for your explicit approval; each approval is a durable, traced record.",
    "Permission: every action is scoped by Security Central; onboarding grants no new authority.",
    "Traces: what Allbert does is recorded and locally inspectable.",
    "Local-first: your data and model stay on your machine unless you connect a hosted provider."
  ]

  @doc "The trust-spine safety properties surfaced during onboarding (M7)."
  @spec trust_spine() :: [String.t()]
  def trust_spine, do: @trust_spine

  @applied_persona_key "applied_persona"

  @doc "Record the persona the operator applied (M7.4) so `first_chat` can suggest its prompts."
  @spec record_applied_persona(String.t()) :: :ok
  def record_applied_persona(persona_id) when is_binary(persona_id) do
    FirstRun.merge_marker(%{@applied_persona_key => persona_id})
  end

  @doc "The applied persona id from the marker, if any."
  @spec applied_persona() :: String.t() | nil
  def applied_persona, do: FirstRun.read_marker()[@applied_persona_key]

  @doc """
  Starter prompts for the `first_chat` step (M7.4): the applied persona's
  `first_chat_prompts`, defaulting to `general` when no persona was applied.
  """
  @spec first_chat_prompts() :: [String.t()]
  def first_chat_prompts do
    Personas.first_chat_prompts(applied_persona() || "general")
  end

  @doc "The 8 canonical wizard step ids, in order."
  @spec wizard_steps() :: [wizard_step(), ...]
  def wizard_steps, do: @wizard_steps

  @doc "The supported wizard tracks."
  @spec wizard_tracks() :: [track(), ...]
  def wizard_tracks, do: @wizard_tracks

  @doc """
  Start (or restart) the wizard on a track. Seeds the marker with the track and
  positions at `welcome`. Returns the wizard state.
  """
  @spec wizard_start(track(), keyword()) :: wizard()
  def wizard_start(track \\ :quickstart, opts \\ []) when track in @wizard_tracks do
    FirstRun.merge_marker(%{
      "wizard_started" => true,
      "track" => Atom.to_string(track),
      "wizard_step" => "welcome",
      "wizard_done" => []
    })

    wizard_state(opts)
  end

  @doc """
  The current wizard state derived from the marker + first-run detection:
  `%{track, step, done, next, readiness, complete?, profile_reviewed?}`.
  """
  @spec wizard_state(keyword()) :: wizard()
  def wizard_state(opts \\ []) do
    marker = FirstRun.read_marker()
    done = wizard_done(marker)
    step = current_wizard_step(marker, done)

    %{
      started?: marker["wizard_started"] == true,
      track: wizard_track(marker),
      step: step,
      done: done,
      next: next_wizard_step(step, wizard_track(marker)),
      readiness: readiness_label(opts),
      profile_reviewed?: marker["profile_reviewed"] == true,
      complete?: marker["onboarding_complete"] == true,
      detect: FirstRun.detect()
    }
  end

  @doc "Resume the wizard — read-only current state."
  @spec wizard_resume(keyword()) :: wizard()
  def wizard_resume(opts \\ []), do: wizard_state(opts)

  @doc """
  Advance past `step` (which must be the current step). Records step completion in
  the marker; `profile_review` also marks the real profile-reviewed state, and
  the terminal `first_chat` marks onboarding complete. Returns `{:ok, state}` or
  `{:error, {:not_current_step, current}}`.
  """
  @spec wizard_advance(wizard_step(), map(), keyword()) ::
          {:ok, wizard()}
          | {:error, {:not_current_step, wizard_step()} | {:unknown_step, String.t()}}
  def wizard_advance(step, result \\ %{}, opts \\ [])
      when is_binary(step) and is_map(result) do
    marker = FirstRun.read_marker()
    done = wizard_done(marker)
    current = current_wizard_step(marker, done)

    cond do
      step not in @wizard_steps ->
        {:error, {:unknown_step, step}}

      step != current ->
        {:error, {:not_current_step, current}}

      true ->
        track = wizard_track(marker)
        new_done = Enum.uniq(done ++ [step])
        next = next_wizard_step(step, track)

        FirstRun.merge_marker(%{"wizard_done" => new_done, "wizard_step" => next || step})
        if step == "profile_review", do: FirstRun.mark_profile_reviewed()
        # v0.63 M7.1: completion fires on the *track's* last step — `first_chat` for
        # QuickStart (optional_connect deferred), `optional_connect` for Advanced — so
        # Advanced's optional_connect stays reachable and `complete?`/`step` agree.
        if step == last_wizard_step(track), do: FirstRun.mark_onboarding_complete()

        {:ok, wizard_state(opts)}
    end
  end

  @doc """
  Reset the wizard: clears the marker (onboarding/profile/wizard progress) and
  reframes/cancels any in-flight onboarding objective; preserves all other Home
  data. Returns the fresh wizard state.
  """
  @spec wizard_reset(keyword()) :: wizard()
  def wizard_reset(opts \\ []) do
    FirstRun.reset_onboarding()
    cancel_active_objective(Keyword.get(opts, :user_id, "local"))
    wizard_state(opts)
  end

  @reconcile_flag "objective_reconciled_v063"

  @doc """
  One-time first-launch reconcile (v0.63 M7.6). A partially-onboarded v0.62 Home may
  carry a stale in-flight onboarding objective alongside the marker; the marker is now
  the sole source of truth, so cancel/reframe that objective once. Marker-guarded (runs
  the objective query at most once per Home), idempotent, and best-effort — it never
  raises out of a surface load. Surfaces call it on first-run load; a fresh v0.63 Home
  finds nothing and simply records the flag.
  """
  @spec reconcile_stale_objective(keyword()) :: :ok
  def reconcile_stale_objective(opts \\ []) do
    if FirstRun.read_marker()[@reconcile_flag] == true do
      :ok
    else
      cancel_active_objective(Keyword.get(opts, :user_id, "local"))
      FirstRun.merge_marker(%{@reconcile_flag => true})
      :ok
    end
  rescue
    _error -> :ok
  end

  @doc "A compact wizard status map (surface-agnostic summary)."
  @spec wizard_status(keyword()) :: wizard_status()
  def wizard_status(opts \\ []) do
    s = wizard_state(opts)

    %{
      started?: s.started?,
      track: s.track,
      step: s.step,
      readiness: s.readiness,
      complete?: s.complete?,
      profile_reviewed?: s.profile_reviewed?
    }
  end

  # -- wizard helpers --------------------------------------------------------

  defp wizard_track(marker) do
    case marker["track"] do
      "advanced" -> :advanced
      _ -> :quickstart
    end
  end

  defp wizard_done(marker) do
    case marker["wizard_done"] do
      list when is_list(list) -> Enum.filter(list, &(&1 in @wizard_steps))
      _ -> []
    end
  end

  # The current step is the first step of the *track's* sequence not yet marked done
  # (the marker's `wizard_step` is an optimization/hint; `done` is authoritative). Once
  # every track step is done it stays on the track's last step — never a step outside
  # the track (M7.1: QuickStart never derives `optional_connect`).
  defp current_wizard_step(marker, done) do
    steps = track_steps(wizard_track(marker))
    Enum.find(steps, List.last(steps), &(&1 not in done))
  end

  defp next_wizard_step(step, track) do
    remaining =
      track
      |> track_steps()
      |> Enum.drop_while(&(&1 != step))
      |> Enum.drop(1)

    List.first(remaining)
  end

  # QuickStart defers optional_connect (channel/integration setup) past first chat; it
  # is not part of the QuickStart sequence. Advanced keeps it as the final step.
  defp track_steps(:quickstart), do: @wizard_steps -- ["optional_connect"]
  defp track_steps(_advanced), do: @wizard_steps

  defp last_wizard_step(track), do: track |> track_steps() |> List.last()

  @doc """
  Map the first-model probe state to an operator readiness label per the plan's
  Readiness Label Mapping Contract. `Needs credentials` / `Needs review` from the
  provider/profile layer are produced by M2/M3/M4, not by this probe mapping.
  """
  @spec readiness_label(keyword()) :: probe_readiness()
  def readiness_label(opts \\ []) do
    # M7.2: get_lazy so an injected probe skips the live probe entirely (the old
    # eager default ran `first_model_state/0` on *every* call, injected or not).
    probe = Keyword.get_lazy(opts, :first_model_state, &safe_first_model_state/0)

    case probe do
      :local_ready -> :ready
      :byok_ready -> :ready
      :runtime_missing -> :needs_runtime
      :runtime_unhealthy -> :needs_runtime
      :model_missing -> :needs_model
      :below_hardware_floor -> :needs_review
    end
  end

  @doc """
  Guarded first-model probe: never raises out of a wizard render. A probe-layer
  exception or a hung/absent local runtime degrades to `:runtime_missing` (→
  `Needs runtime`) rather than blocking or crashing the surface (M7.2).
  """
  @spec safe_first_model_state() :: FirstRun.model_state()
  def safe_first_model_state do
    FirstRun.first_model_state()
  rescue
    _error -> :runtime_missing
  catch
    :exit, _reason -> :runtime_missing
  end

  @doc """
  Track-aware `model_path` guidance: turns the first-model probe into an
  operator-language headline plus the *single* next action to route to. QuickStart
  frames the recommended path assertively; Advanced adds that provider/model choices
  are available up front. Every non-ready outcome is `repairable?: true` with a
  concrete `action` — the M2 no-dead-end invariant (QuickStart never ends without a
  usable model or a specific repair). Operator copy never leaks a raw probe atom.
  """
  @spec model_path_guidance(keyword()) :: model_guidance()
  def model_path_guidance(opts \\ []) do
    probe = Keyword.get_lazy(opts, :first_model_state, &safe_first_model_state/0)
    track = Keyword.get(opts, :track, :quickstart)
    label = readiness_label(first_model_state: probe)
    build_guidance(label, track)
  end

  @doc """
  Guidance from an already-resolved readiness label + track — lets surfaces that
  already hold `wizard.readiness` render the next action without re-probing.
  """
  @spec model_guidance_for(readiness(), track()) :: model_guidance()
  def model_guidance_for(readiness, track)
      when readiness in [:ready, :needs_model, :needs_runtime, :needs_review, :needs_credentials] and
             track in @wizard_tracks,
      do: build_guidance(readiness, track)

  defp build_guidance(:ready, _track) do
    %{
      readiness: :ready,
      headline: "Your model is ready.",
      next_action: "Start your first chat.",
      action: :start_chat,
      repairable?: true,
      reaches_chat?: true
    }
  end

  defp build_guidance(:needs_runtime, track) do
    %{
      readiness: :needs_runtime,
      headline: "No local model runtime is running yet.",
      next_action:
        advanced_suffix(
          track,
          "Install and start the local runtime (Ollama) with `allbert admin model install`.",
          "or switch to a hosted provider now."
        ),
      action: :install_runtime,
      repairable?: true,
      reaches_chat?: false
    }
  end

  defp build_guidance(:needs_model, track) do
    %{
      readiness: :needs_model,
      headline: "The runtime is up, but the starter model isn't downloaded.",
      next_action:
        advanced_suffix(
          track,
          "Pull the starter model with `allbert admin model pull`.",
          "or pick a different model/provider."
        ),
      action: :pull_model,
      repairable?: true,
      reaches_chat?: false
    }
  end

  defp build_guidance(:needs_review, track) do
    %{
      readiness: :needs_review,
      headline: "This machine is below the local-model hardware floor.",
      next_action:
        advanced_suffix(
          track,
          "Connect a hosted provider (bring your own key) to reach a working chat.",
          "or review the model/provider options."
        ),
      action: :choose_provider,
      repairable?: true,
      reaches_chat?: false
    }
  end

  defp build_guidance(:needs_credentials, track) do
    %{
      readiness: :needs_credentials,
      headline: "The chosen provider needs a credential before it can be used.",
      next_action:
        advanced_suffix(
          track,
          "Enter the provider key (stored masked in the secret vault).",
          "or pick a different provider or the local runtime."
        ),
      action: :enter_credentials,
      repairable?: true,
      reaches_chat?: false
    }
  end

  # Advanced surfaces the extra provider/model choice inline; QuickStart stays terse.
  defp advanced_suffix(:advanced, base, extra), do: base <> " (Advanced: " <> extra <> ")"
  defp advanced_suffix(_quickstart, base, _extra), do: base

  # Best-effort: `--reset` must always clear the marker even if the objective
  # store is unavailable, so a cancel failure never blocks the reset.
  defp cancel_active_objective(user_id) do
    with {:ok, user_id} <- normalize_user_id(user_id),
         {:ok, %Objective{} = objective} <-
           Objectives.find_active_by_source_intent(user_id, @source_intent) do
      _ = Objectives.update_objective(objective, %{status: "cancelled", current_step_id: nil})
      :ok
    else
      _ -> :ok
    end
  rescue
    _error -> :ok
  end

  defp normalize_user_id(user_id) when is_binary(user_id) do
    case String.trim(user_id) do
      "" -> {:error, :missing_user_id}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_user_id(_user_id), do: {:error, :missing_user_id}
end
