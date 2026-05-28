defmodule AllbertAssist.Onboarding do
  @moduledoc """
  First-run onboarding objective skeleton.

  v0.39 M1 keeps this as a plain context module. It owns no process state; the
  durable state is the shared objective runtime tables.
  """

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.{Objective, Step}

  @source_intent "first_run_onboarding"
  @active_statuses ~w[open running blocked]
  @complete_statuses ~w[completed skipped cancelled]

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
         {:ok, status} <- step_status(attrs),
         {:ok, step} <- Objectives.transition_step(step, status, step_result_attrs(attrs, status)),
         {:ok, _event} <- record_step_event(objective, step, status, attrs),
         {:ok, objective} <- sync_current_step(objective) do
      {:ok, state(objective, false) |> Map.put(:completed_step, step_map(step))}
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

    %{
      objective: objective_map(objective),
      steps: Enum.map(steps, &step_map/1),
      current_step: maybe_step_map(current_step),
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

  defp step_map(%Step{} = step) do
    params = decode_params(step.action_params)

    %{
      id: step.id,
      objective_id: step.objective_id,
      index: params["index"],
      key: params["step_key"],
      title: params["title"] || step.result_summary,
      optional?: params["optional?"] || false,
      kind: step.kind,
      status: step.status,
      stage: step.stage,
      candidate_action: step.candidate_action
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp maybe_step_map(nil), do: nil
  defp maybe_step_map(%Step{} = step), do: step_map(step)

  defp fetch_step(objective_id, step_id) do
    objective_id
    |> ordered_steps()
    |> Enum.find(&(&1.id == step_id))
    |> case do
      %Step{} = step -> {:ok, step}
      nil -> {:error, :onboarding_step_not_found}
    end
  end

  defp step_status(attrs) do
    outcome =
      attrs
      |> field(:outcome)
      |> case do
        nil -> field(attrs, :status)
        value -> value
      end
      |> normalize_status()

    if outcome in ["completed", "skipped"] do
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

    %{result_summary: summary}
  end

  defp record_step_event(objective, step, status, attrs) do
    Objectives.create_event(%{
      objective_id: objective.id,
      step_id: step.id,
      kind: "step_completed",
      summary: "#{step_map(step).title} #{status}.",
      payload: %{
        step_key: step_key(step),
        outcome: status,
        note: field(attrs, :note)
      }
    })
  end

  defp progress_summary(steps) do
    total = length(steps)
    completed = Enum.count(steps, &complete_step?/1)
    "#{completed}/#{total} onboarding steps completed or skipped."
  end

  defp running_status(status) when status in @active_statuses, do: "running"
  defp running_status(_status), do: "running"

  defp complete_step?(%Step{status: status}), do: status in @complete_statuses

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
