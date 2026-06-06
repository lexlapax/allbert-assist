defmodule AllbertAssist.Onboarding do
  @moduledoc """
  First-run onboarding objective skeleton.

  v0.39 M1 keeps this as a plain context module. It owns no process state; the
  durable state is the shared objective runtime tables.
  """

  alias AllbertAssist.{Channels, Memory, Objectives, Settings}
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
