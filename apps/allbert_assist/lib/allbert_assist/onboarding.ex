defmodule AllbertAssist.Onboarding do
  @moduledoc """
  First-run onboarding objective skeleton.

  v0.39 M1 keeps this as a plain context module. It owns no process state; the
  durable state is the shared objective runtime tables.
  """

  alias AllbertAssist.{Channels, Memory, Objectives, Settings}
  alias AllbertAssist.CLI.FirstRun
  alias AllbertAssist.Objectives.{Objective, Step}
  alias AllbertAssist.Runtime.Paths

  @source_intent "first_run_onboarding"
  @active_statuses ~w[open running blocked]
  @complete_statuses ~w[completed skipped cancelled]
  @channel_step_key "optional_channel_registration"

  @steps [
    %{
      key: "welcome_scope",
      title: "Welcome + scope",
      kind: "ask_user",
      stage: "frame_objective",
      optional?: false
    },
    %{
      key: "pick_provider_profile",
      title: "Pick provider profile",
      kind: "ask_user",
      stage: "execute_step",
      optional?: false
    },
    %{
      key: "resolve_credential_or_endpoint",
      title: "Resolve credential or endpoint",
      kind: "action",
      stage: "execute_step",
      candidate_action: "set_provider_credential",
      optional?: false
    },
    %{
      key: "run_doctor",
      title: "Run doctor",
      kind: "action",
      stage: "execute_step",
      candidate_action: "doctor_model_profile",
      optional?: false
    },
    %{
      key: "pick_model_profile",
      title: "Pick model profile",
      kind: "action",
      stage: "execute_step",
      candidate_action: "set_active_model_profile",
      optional?: false
    },
    %{
      key: "toggle_model_assisted_intent",
      title: "Toggle model-assisted intent",
      kind: "action",
      stage: "execute_step",
      candidate_action: "set_active_model_profile",
      optional?: false
    },
    %{
      key: "optional_channel_registration",
      title: "Optional channel registration",
      kind: "ask_user",
      stage: "execute_step",
      optional?: true
    },
    %{
      key: "identity_slot_preview",
      title: "Identity slot preview",
      kind: "observe",
      stage: "observe_step",
      optional?: true
    },
    %{
      key: "done",
      title: "Done",
      kind: "observe",
      stage: "advance_objective",
      optional?: false
    }
  ]

  @doc "Return the v0.39 onboarding source intent marker."
  @spec source_intent() :: String.t()
  def source_intent, do: @source_intent

  @doc "Return the planned onboarding step definitions."
  @spec step_definitions() :: [map()]
  def step_definitions, do: indexed_steps()

  @doc "Frame or resume the single active onboarding objective for a user."
  @spec frame_or_resume(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def frame_or_resume(user_id, context \\ %{}) when is_map(context) do
    with {:ok, user_id} <- normalize_user_id(user_id),
         {:ok, objective, created?} <- fetch_or_create_objective(user_id, context),
         {:ok, _steps} <- ensure_steps(objective),
         {:ok, objective} <- sync_current_step(objective) do
      {:ok, state(objective, created?)}
    end
  end

  @doc "Record completion or skip for one onboarding step."
  @spec complete_step(String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def complete_step(user_id, objective_id, step_id, attrs \\ %{})

  def complete_step(user_id, objective_id, step_id, attrs)
      when is_binary(objective_id) and is_binary(step_id) and is_map(attrs) do
    with {:ok, user_id} <- normalize_user_id(user_id),
         {:ok, objective} <- Objectives.get_objective(user_id, objective_id),
         {:ok, step} <- fetch_step(objective.id, step_id),
         {:ok, status} <- step_status(attrs, step),
         {:ok, step} <- Objectives.transition_step(step, status, step_result_attrs(attrs, status)),
         {:ok, _event} <- record_step_event(objective, step, status, attrs),
         {:ok, objective} <- sync_current_step(objective) do
      evidence = evidence_snapshot()
      {:ok, state(objective, false) |> Map.put(:completed_step, step_map(step, evidence))}
    end
  end

  def complete_step(_user_id, _objective_id, _step_id, _attrs),
    do: {:error, :invalid_onboarding_step}

  # ==========================================================================
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
        # The wizard is "complete" once the operator reaches first useful chat;
        # optional_connect is deferred and does not gate completion.
        if step == "first_chat", do: FirstRun.mark_onboarding_complete()

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

  # The current step is the first canonical step not yet marked done (the marker's
  # `wizard_step` is an optimization/hint; `done` is authoritative).
  defp current_wizard_step(_marker, done) do
    Enum.find(@wizard_steps, "optional_connect", &(&1 not in done))
  end

  defp next_wizard_step(step, track) do
    remaining =
      @wizard_steps
      |> Enum.drop_while(&(&1 != step))
      |> Enum.drop(1)
      |> maybe_skip_optional(track)

    List.first(remaining)
  end

  # QuickStart defers optional_connect (channel/integration setup) past first chat;
  # it is not a completion gate. Advanced keeps it in sequence.
  defp maybe_skip_optional(steps, :quickstart), do: steps -- ["optional_connect"]
  defp maybe_skip_optional(steps, _advanced), do: steps

  @doc """
  Map the first-model probe state to an operator readiness label per the plan's
  Readiness Label Mapping Contract. `Needs credentials` / `Needs review` from the
  provider/profile layer are produced by M2/M3/M4, not by this probe mapping.
  """
  @spec readiness_label(keyword()) :: probe_readiness()
  def readiness_label(opts \\ []) do
    probe = Keyword.get(opts, :first_model_state, FirstRun.first_model_state())

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
  Track-aware `model_path` guidance: turns the first-model probe into an
  operator-language headline plus the *single* next action to route to. QuickStart
  frames the recommended path assertively; Advanced adds that provider/model choices
  are available up front. Every non-ready outcome is `repairable?: true` with a
  concrete `action` — the M2 no-dead-end invariant (QuickStart never ends without a
  usable model or a specific repair). Operator copy never leaks a raw probe atom.
  """
  @spec model_path_guidance(keyword()) :: model_guidance()
  def model_path_guidance(opts \\ []) do
    probe = Keyword.get(opts, :first_model_state, FirstRun.first_model_state())
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

  defp fetch_or_create_objective(user_id, context) do
    case Objectives.find_active_by_source_intent(user_id, @source_intent) do
      {:ok, %Objective{} = objective} ->
        {:ok, objective, false}

      {:error, :not_found} ->
        create_objective(user_id, context)
    end
  end

  defp create_objective(user_id, context) do
    with {:ok, objective} <-
           Objectives.create_objective(%{
             user_id: user_id,
             status: "open",
             title: "First-run onboarding",
             objective:
               "Guide the operator through first-run provider, model, and channel setup.",
             acceptance_criteria: %{
               "operator_visible" => true,
               "safe_keys_only" => true,
               "identity_slot_preview_only" => true
             },
             active_app: "allbert",
             source_thread_id: field(context, :thread_id),
             session_id: field(context, :session_id),
             source_intent: @source_intent
           }),
         {:ok, _event} <-
           Objectives.create_event(%{
             objective_id: objective.id,
             kind: "created",
             summary: "First-run onboarding objective framed.",
             payload: %{source_intent: @source_intent}
           }) do
      {:ok, objective, true}
    end
  end

  defp ensure_steps(%Objective{} = objective) do
    existing = ordered_steps(objective.id)
    existing_keys = MapSet.new(Enum.map(existing, &step_key/1))

    indexed_steps()
    |> Enum.reject(&MapSet.member?(existing_keys, &1.key))
    |> Enum.reduce_while({:ok, existing}, fn attrs, {:ok, acc} ->
      case create_step(objective, attrs) do
        {:ok, step} -> {:cont, {:ok, [step | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp create_step(objective, attrs) do
    params =
      attrs
      |> Map.take([:index, :key, :title, :optional?])
      |> Map.put(:step_key, attrs.key)
      |> Map.delete(:key)

    with {:ok, step} <-
           Objectives.create_step(%{
             objective_id: objective.id,
             kind: attrs.kind,
             status: "proposed",
             stage: attrs.stage,
             candidate_action: Map.get(attrs, :candidate_action),
             action_params: params,
             result_summary: attrs.title
           }),
         {:ok, _event} <-
           Objectives.create_event(%{
             objective_id: objective.id,
             step_id: step.id,
             kind: "step_proposed",
             summary: attrs.title,
             payload: %{step_key: attrs.key, optional?: attrs.optional?}
           }) do
      {:ok, step}
    end
  end

  defp sync_current_step(%Objective{} = objective) do
    steps = ordered_steps(objective.id)
    current_step = Enum.find(steps, &(not complete_step?(&1)))

    attrs =
      if current_step do
        %{
          current_step_id: current_step.id,
          status: running_status(objective.status),
          progress_summary: progress_summary(steps)
        }
      else
        %{
          current_step_id: nil,
          status: "completed",
          progress_summary: progress_summary(steps),
          completed_at: DateTime.utc_now()
        }
      end

    with {:ok, objective} <- Objectives.update_objective(objective, attrs) do
      maybe_record_completed_event(objective, current_step)
    end
  end

  defp maybe_record_completed_event(%Objective{status: "completed"} = objective, nil) do
    case already_completed_event?(objective.id) do
      true ->
        {:ok, objective}

      false ->
        with {:ok, _event} <-
               Objectives.create_event(%{
                 objective_id: objective.id,
                 kind: "completed",
                 summary: "First-run onboarding completed.",
                 payload: %{source_intent: @source_intent}
               }) do
          {:ok, objective}
        end
    end
  end

  defp maybe_record_completed_event(objective, _current_step), do: {:ok, objective}

  defp already_completed_event?(objective_id) do
    objective_id
    |> Objectives.list_events(limit: 100)
    |> Enum.any?(&(&1.kind == "completed"))
  end

  defp state(%Objective{} = objective, created?) do
    steps = ordered_steps(objective.id)
    current_step = Enum.find(steps, &(not complete_step?(&1)))
    evidence = evidence_snapshot()

    %{
      objective: objective_map(objective),
      steps: Enum.map(steps, &step_map(&1, evidence)),
      current_step: maybe_step_map(current_step, evidence),
      evidence: evidence,
      created?: created?
    }
  end

  defp objective_map(%Objective{} = objective) do
    %{
      id: objective.id,
      user_id: objective.user_id,
      title: objective.title,
      objective: objective.objective,
      status: objective.status,
      active_app: objective.active_app,
      source_intent: objective.source_intent,
      current_step_id: objective.current_step_id,
      progress_summary: objective.progress_summary
    }
  end

  defp step_map(%Step{} = step, evidence) do
    params = decode_params(step.action_params)
    key = params["step_key"]

    %{
      id: step.id,
      objective_id: step.objective_id,
      index: params["index"],
      key: key,
      title: params["title"] || step.result_summary,
      optional?: params["optional?"] || false,
      kind: step.kind,
      status: step.status,
      stage: step.stage,
      candidate_action: step.candidate_action,
      evidence: evidence_for_step(key, evidence),
      next_command: next_command_for_step(key, evidence),
      recorded_evidence: step.observation_summary
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp maybe_step_map(nil, _evidence), do: nil
  defp maybe_step_map(%Step{} = step, evidence), do: step_map(step, evidence)

  defp fetch_step(objective_id, step_id) do
    objective_id
    |> ordered_steps()
    |> Enum.find(&(&1.id == step_id))
    |> case do
      %Step{} = step -> {:ok, step}
      nil -> {:error, :onboarding_step_not_found}
    end
  end

  defp step_status(attrs, %Step{} = step) do
    outcome =
      attrs
      |> field(:outcome)
      |> case do
        nil -> field(attrs, :status)
        value -> value
      end
      |> normalize_status()

    if outcome in allowed_step_statuses(step) do
      {:ok, outcome}
    else
      {:error, {:invalid_onboarding_step_outcome, outcome}}
    end
  end

  defp step_result_attrs(attrs, status) do
    summary =
      attrs
      |> field(:note)
      |> case do
        value when is_binary(value) and value != "" -> value
        _other -> "Onboarding step #{status}."
      end

    %{
      result_summary: summary,
      observation_summary: evidence_summary(field(attrs, :evidence))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp record_step_event(objective, step, status, attrs) do
    Objectives.create_event(%{
      objective_id: objective.id,
      step_id: step.id,
      kind: step_event_kind(status),
      summary: "#{step_map(step, evidence_snapshot()).title} #{status}.",
      payload: %{
        step_key: step_key(step),
        outcome: status,
        note: field(attrs, :note),
        evidence: field(attrs, :evidence)
      }
    })
  end

  defp allowed_step_statuses(step) do
    case step_key(step) do
      @channel_step_key -> ["completed", "skipped", "selected"]
      _other -> ["completed", "skipped"]
    end
  end

  defp step_event_kind("selected"), do: "step_selected"
  defp step_event_kind(_status), do: "step_completed"

  defp progress_summary(steps) do
    total = length(steps)
    completed = Enum.count(steps, &complete_step?/1)
    "#{completed}/#{total} onboarding steps completed or skipped."
  end

  defp running_status(status) when status in @active_statuses, do: "running"
  defp running_status(_status), do: "running"

  defp complete_step?(%Step{status: status}), do: status in @complete_statuses

  defp evidence_snapshot do
    active_model_profile = setting_value("intent.model_profile", "local")

    direct_answer_profile =
      setting_value("intent.direct_answer_model_profile", active_model_profile)

    providers = settings_list(&Settings.list_provider_profiles/0)
    models = settings_list(&Settings.list_model_profiles/0)
    channels = Channels.list_channels()

    active_model = Enum.find(models, &(&1.name == active_model_profile))
    active_provider = Enum.find(providers, &(&1.name == provider_name(active_model)))
    identity_entries = identity_entries()
    kept_identity_count = Enum.count(identity_entries, &(&1.review_status == :kept))

    %{
      active_model_profile: active_model_profile,
      direct_answer_model_profile: direct_answer_profile,
      model_preferences: model_preferences_snapshot(),
      model_assist_enabled?: setting_value("intent.model_assist_enabled", false),
      direct_answer_model_enabled?: setting_value("intent.direct_answer_model_enabled", false),
      active_memory_enabled?: setting_value("active_memory.enabled", true),
      active_model: summarize_model(active_model),
      active_provider: summarize_provider(active_provider),
      model_profiles: Enum.map(models, &summarize_model/1),
      provider_profiles: Enum.map(providers, &summarize_provider/1),
      channels: Enum.map(channels, &summarize_channel/1),
      identity_root: Path.join(Paths.memory_root(), "identity"),
      identity_entry_count: length(identity_entries),
      kept_identity_count: kept_identity_count
    }
  end

  defp evidence_for_step("welcome_scope", evidence) do
    "Onboarding writes objective progress only. Active model profile: #{evidence.active_model_profile}."
  end

  defp evidence_for_step("pick_provider_profile", evidence) do
    provider = evidence.active_provider || %{}

    "Active provider: #{Map.get(provider, :name, "unknown")} endpoint_kind=#{Map.get(provider, :endpoint_kind, "unknown")} enabled=#{Map.get(provider, :enabled, "unknown")} credential=#{Map.get(provider, :credential_status, "unknown")}."
  end

  defp evidence_for_step("resolve_credential_or_endpoint", evidence) do
    provider = evidence.active_provider || %{}

    "Provider #{Map.get(provider, :name, "unknown")} credential=#{Map.get(provider, :credential_status, "unknown")}; local endpoints are checked by doctor and remote credentials stay in Settings Central secrets."
  end

  defp evidence_for_step("run_doctor", evidence) do
    model = evidence.active_model || %{}

    "Doctor target: model_profile=#{evidence.active_model_profile} provider=#{Map.get(model, :provider, "unknown")} model=#{Map.get(model, :model, "unknown")}."
  end

  defp evidence_for_step("pick_model_profile", evidence) do
    model = evidence.active_model || %{}
    preferences = evidence.model_preferences

    "Primary model preference: #{preferences.primary}; active model profile: #{evidence.active_model_profile} provider=#{Map.get(model, :provider, "unknown")} model=#{Map.get(model, :model, "unknown")}; direct_answer=#{inspect(preferences.direct_answer)}; speech_to_text=#{inspect(preferences.speech_to_text)}; text_to_speech=#{inspect(preferences.text_to_speech)}."
  end

  defp evidence_for_step("toggle_model_assisted_intent", evidence) do
    "Model-assisted intent enabled=#{evidence.model_assist_enabled?}; direct-answer model enabled=#{evidence.direct_answer_model_enabled?}."
  end

  defp evidence_for_step(@channel_step_key, evidence) do
    evidence.channels
    |> Enum.map(
      &"#{&1.channel}: enabled=#{&1.enabled} identities=#{&1.identity_count} credentials=#{credential_status_summary(&1.credential_status)}"
    )
    |> Enum.join("; ")
    |> case do
      "" -> "No channel adapters are registered."
      summary -> summary
    end
  end

  defp evidence_for_step("identity_slot_preview", evidence) do
    "Identity root: #{evidence.identity_root}; kept identity entries=#{evidence.kept_identity_count}; active_memory.enabled=#{evidence.active_memory_enabled?}; direct_answer_model_enabled=#{evidence.direct_answer_model_enabled?}."
  end

  defp evidence_for_step("done", evidence) do
    "Ready to close after provider/model evidence, channel decision, and Active Memory preview are reviewed. Active model profile: #{evidence.active_model_profile}."
  end

  defp evidence_for_step(_key, _evidence), do: nil

  defp next_command_for_step("welcome_scope", _evidence),
    do: "mix allbert.onboard complete welcome_scope"

  defp next_command_for_step("pick_provider_profile", _evidence),
    do: "mix allbert.model list"

  defp next_command_for_step("resolve_credential_or_endpoint", evidence) do
    case endpoint_kind(evidence.active_provider) do
      "local_endpoint" -> "mix allbert.model doctor #{evidence.active_model_profile}"
      _other -> "printf '<api-key>\\n' | mix allbert.settings providers set-key <provider>"
    end
  end

  defp next_command_for_step("run_doctor", evidence),
    do: "mix allbert.model doctor #{evidence.active_model_profile}"

  defp next_command_for_step("pick_model_profile", _evidence),
    do: "mix allbert.model use local"

  defp next_command_for_step("toggle_model_assisted_intent", _evidence),
    do: "mix allbert.model use local --enable-assist"

  defp next_command_for_step(@channel_step_key, _evidence),
    do: "mix allbert.channels list"

  defp next_command_for_step("identity_slot_preview", _evidence),
    do: "mix allbert.memory retrieve --query \"concise release reports\""

  defp next_command_for_step("done", _evidence),
    do: "mix allbert.onboard complete done"

  defp next_command_for_step(_key, _evidence), do: nil

  defp provider_name(%{provider: provider}), do: provider
  defp provider_name(_model), do: nil

  defp endpoint_kind(%{endpoint_kind: endpoint_kind}), do: endpoint_kind
  defp endpoint_kind(_provider), do: nil

  defp settings_list(fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, values} when is_list(values) -> values
      _other -> []
    end
  end

  defp setting_value(key, fallback) do
    case Settings.get(key) do
      {:ok, value} -> value
      _other -> fallback
    end
  end

  defp model_preferences_snapshot do
    %{
      primary: setting_value("model_preferences.primary", "local"),
      coding: setting_value("model_preferences.tasks.coding", []),
      direct_answer: setting_value("model_preferences.tasks.direct_answer", []),
      text_generation: setting_value("model_preferences.capabilities.text_generation", []),
      speech_to_text: setting_value("model_preferences.capabilities.speech_to_text", []),
      text_to_speech: setting_value("model_preferences.capabilities.text_to_speech", [])
    }
  end

  defp identity_entries do
    identity_root = Path.join(Paths.memory_root(), "identity")

    if File.dir?(identity_root) do
      identity_root
      |> Path.join("**/*.md")
      |> Path.wildcard()
      |> Enum.flat_map(&read_identity_entry/1)
    else
      []
    end
  end

  defp read_identity_entry(path) do
    case Memory.read_entry(path) do
      {:ok, entry} -> [entry]
      {:error, _reason} -> []
    end
  end

  defp summarize_model(nil), do: nil

  defp summarize_model(model) do
    %{
      name: model.name,
      provider: model.provider,
      provider_enabled: model.provider_enabled,
      endpoint_kind: model.provider_endpoint_kind,
      model: model.model,
      credential_status: model.credential_status
    }
  end

  defp summarize_provider(nil), do: nil

  defp summarize_provider(provider) do
    %{
      name: provider.name,
      enabled: provider.enabled,
      endpoint_kind: provider.endpoint_kind,
      credential_status: provider.credential_status
    }
  end

  defp summarize_channel(channel) do
    %{
      channel: channel.channel,
      enabled: channel.enabled,
      identity_count: channel.identity_count,
      credential_status: channel.credential_status
    }
  end

  defp credential_status_summary(status) when is_map(status) and map_size(status) == 0,
    do: "none required"

  defp credential_status_summary(status) when is_map(status) do
    status
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} ->
      "#{credential_label(key)} #{credential_status_label(value)}"
    end)
    |> Enum.join(", ")
  end

  defp credential_status_summary(_status), do: "unknown"

  defp credential_label(key) when is_binary(key) do
    key
    |> String.split(".")
    |> List.last()
    |> String.replace_suffix("_ref", "")
    |> String.replace("_", " ")
  end

  defp credential_label(key), do: to_string(key)

  defp credential_status_label(:configured), do: "configured"
  defp credential_status_label(:missing), do: "missing"
  defp credential_status_label(:decrypt_failed), do: "cannot be read"
  defp credential_status_label(:invalid_ref), do: "has an invalid reference"
  defp credential_status_label(_status), do: "unknown"

  defp evidence_summary(nil), do: nil

  defp evidence_summary(evidence) when is_binary(evidence), do: evidence

  defp evidence_summary(evidence) when is_map(evidence) do
    evidence
    |> Enum.map(fn {key, value} -> "#{key}=#{inspect(value)}" end)
    |> Enum.join("; ")
    |> truncate_summary()
  end

  defp evidence_summary(_evidence), do: nil

  defp truncate_summary(summary) when byte_size(summary) > 1_900,
    do: binary_part(summary, 0, 1_900)

  defp truncate_summary(summary), do: summary

  defp indexed_steps do
    @steps
    |> Enum.with_index(1)
    |> Enum.map(fn {step, index} -> Map.put(step, :index, index) end)
  end

  defp ordered_steps(objective_id) do
    objective_id
    |> Objectives.list_steps()
    |> Enum.sort_by(fn step ->
      params = decode_params(step.action_params)
      {params["index"] || 999, step.inserted_at, step.id}
    end)
  end

  defp step_key(%Step{} = step), do: Map.get(decode_params(step.action_params), "step_key")

  defp decode_params(nil), do: %{}
  defp decode_params(%{} = params), do: stringify_keys(params)

  defp decode_params(params) when is_binary(params) do
    case Jason.decode(params) do
      {:ok, %{} = decoded} -> decoded
      _other -> %{}
    end
  end

  defp decode_params(_params), do: %{}

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_user_id(user_id) when is_binary(user_id) do
    case String.trim(user_id) do
      "" -> {:error, :missing_user_id}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_user_id(_user_id), do: {:error, :missing_user_id}

  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)

  defp normalize_status(status) when is_binary(status) do
    status |> String.trim() |> String.downcase()
  end

  defp normalize_status(_status), do: nil

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
