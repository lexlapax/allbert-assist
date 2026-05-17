defmodule AllbertAssist.Objectives.Commands do
  @moduledoc false

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Objectives.Proposer
  alias AllbertAssist.Security.Redactor
  alias AllbertAssist.Signals

  @doc false
  def finish(command, result, state, opts \\ []) do
    case result do
      {:ok, value} ->
        patch =
          state
          |> Map.merge(%{
            last_command: command,
            last_result: {:ok, value},
            last_error: nil
          })
          |> maybe_merge_projection(value)
          |> maybe_put(:last_summary, Keyword.get(opts, :summary))

        {:ok, patch, Keyword.get(opts, :directives, [])}

      {:error, reason} ->
        {:ok,
         %{
           last_command: command,
           last_result: {:error, reason},
           last_error: inspect(reason)
         }}
    end
  end

  @doc false
  def objective_attrs(params) do
    now_title = param(params, :title) || "Objective"

    %{
      user_id: param(params, :user_id),
      source_thread_id: param(params, :source_thread_id),
      session_id: param(params, :session_id),
      active_app: app_value(param(params, :active_app)),
      status: param(params, :status) || "open",
      title: now_title,
      objective: param(params, :objective) || now_title,
      acceptance_criteria: param(params, :acceptance_criteria),
      constraints: param(params, :constraints),
      source_intent: param(params, :source_intent)
    }
  end

  @doc false
  def emit_objective(kind, %Objective{} = objective, metadata \\ %{}) do
    payload =
      metadata
      |> Map.put(:objective_id, objective.id)
      |> Map.put(:user_id, objective.user_id)
      |> Map.put(:source_thread_id, objective.source_thread_id)
      |> Map.put(:session_id, objective.session_id)
      |> Map.put(:active_app, objective.active_app)
      |> Map.put(:stage, Map.get(metadata, :stage))
      |> Map.put(:title, objective.title)
      |> Redactor.redact()

    with {:ok, signal} <- Signals.objective_lifecycle(kind, payload) do
      Signals.log(signal)
    end
  end

  defp maybe_merge_projection(state, %{objective: %Objective{} = objective, steps: steps} = value) do
    stage = Map.get(value, :stage, "propose_steps")

    state
    |> put_objective_projection(objective)
    |> update_nested(:current_stage, objective.id, stage)
    |> update_nested(:loop_counts, objective.id, objective.loop_count || 0)
    |> maybe_put_proposer_hint(objective)
    |> maybe_put(:last_summary, %{objective_id: objective.id, proposed_steps: length(steps)})
  end

  defp maybe_merge_projection(state, %{objective: %Objective{} = objective} = value) do
    stage = Map.get(value, :stage, "frame_objective")

    state
    |> put_objective_projection(objective)
    |> update_nested(:current_stage, objective.id, stage)
    |> update_nested(:loop_counts, objective.id, objective.loop_count || 0)
    |> maybe_put_proposer_hint(objective)
  end

  defp maybe_merge_projection(state, _value), do: state

  defp put_objective_projection(state, %Objective{status: status, id: id} = objective)
       when status in ["open", "running", "blocked"] do
    update_nested(state, :active_objectives, id, Objectives.objective_summary(objective))
  end

  defp put_objective_projection(state, %Objective{id: id}) do
    current = Map.get(state, :active_objectives, %{})
    Map.put(state, :active_objectives, Map.delete(current, id))
  end

  defp maybe_put_proposer_hint(state, %Objective{id: id, proposer_hint: nil}) do
    current = Map.get(state, :proposer_hints, %{})
    Map.put(state, :proposer_hints, Map.delete(current, id))
  end

  defp maybe_put_proposer_hint(state, %Objective{id: id, proposer_hint: hint}) do
    case normalized_proposer_hint(hint) do
      {:ok, normalized_hint} ->
        current = Map.get(state, :proposer_hints, %{})
        Map.put(state, :proposer_hints, Map.put(current, id, normalized_hint))

      :delete ->
        current = Map.get(state, :proposer_hints, %{})
        Map.put(state, :proposer_hints, Map.delete(current, id))

      :skip ->
        state
    end
  end

  defp update_nested(state, key, nested_key, value) do
    current = Map.get(state, key, %{})
    Map.put(state, key, Map.put(current, nested_key, value))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalized_proposer_hint(nil), do: :delete

  defp normalized_proposer_hint(hint) when is_binary(hint) do
    with {:ok, %{} = hint_map} <- Jason.decode(hint),
         {:ok, normalized_hint} when not is_nil(normalized_hint) <-
           Proposer.normalize_hint(hint_map) do
      {:ok, normalized_hint}
    else
      _other -> :skip
    end
  end

  defp normalized_proposer_hint(_hint), do: :skip

  defp param(params, key), do: Map.get(params, key) || Map.get(params, Atom.to_string(key))

  defp app_value(nil), do: nil
  defp app_value(app) when is_atom(app), do: Atom.to_string(app)
  defp app_value(app), do: app
end

defmodule AllbertAssist.Objectives.Commands.FrameObjective do
  @moduledoc false

  use Jido.Action,
    name: "allbert_objectives_frame_objective",
    description: "Private objective framing command."

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Commands

  @impl true
  def run(params, context) do
    state = Map.get(context, :state, %{})
    attrs = Commands.objective_attrs(params)

    with {:ok, objective} <- Objectives.create_objective(attrs),
         {:ok, event} <-
           Objectives.create_event(%{
             objective_id: objective.id,
             kind: "created",
             summary: "Objective created.",
             payload: %{title: objective.title, status: objective.status}
           }) do
      Commands.emit_objective(:created, objective, %{stage: :frame_objective})
      Commands.finish(:frame_objective, {:ok, %{objective: objective, event: event}}, state)
    end
  end
end

defmodule AllbertAssist.Objectives.Commands.ProposeSteps do
  @moduledoc false

  use Jido.Action,
    name: "allbert_objectives_propose_steps",
    description: "Private objective step proposal command."

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Commands
  alias AllbertAssist.Objectives.Proposer
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) do
    state = Map.get(context, :state, %{})

    with {:ok, objective_id} <- objective_id(params),
         {:ok, objective} <- Objectives.get_objective(objective_id),
         {:ok, intent_decision} <- intent_decision(params, objective),
         proposer_context <- proposer_context(params, context, objective, state) do
      intent_decision
      |> Proposer.propose(proposer_context)
      |> handle_proposal(objective, params, state)
    else
      {:error, reason} ->
        Commands.finish(:propose_steps, {:error, reason}, state)
    end
  end

  defp handle_proposal({:ok, _steps, _continuation} = proposal, objective, _params, state) do
    case persist_proposal(objective, proposal) do
      {:ok, result} -> Commands.finish(:propose_steps, {:ok, result}, state)
      {:error, reason} -> Commands.finish(:propose_steps, {:error, reason}, state)
    end
  end

  defp handle_proposal({:no_steps, reason}, _objective, params, state) do
    record_no_steps(params, state, reason)
  end

  defp handle_proposal({:error, reason}, _objective, _params, state) do
    Commands.finish(:propose_steps, {:error, reason}, state)
  end

  defp persist_proposal(objective, {:ok, step_attrs, continuation}) do
    if length(step_attrs) > max_steps_per_turn() do
      record_cap_impasse(objective, :max_steps_per_turn, %{
        proposed_steps: length(step_attrs),
        max_steps_per_turn: max_steps_per_turn()
      })
    else
      do_persist_proposal(objective, {:ok, step_attrs, continuation})
    end
  end

  defp do_persist_proposal(objective, {:ok, step_attrs, continuation}) do
    Repo.transaction(fn ->
      steps = Enum.map(step_attrs, &persist_step!(objective, &1, continuation))
      objective = update_hint!(objective, continuation)

      %{objective: objective, steps: steps, continuation: continuation_summary(continuation)}
    end)
  end

  defp persist_step!(objective, attrs, continuation) do
    attrs
    |> step_attrs(objective)
    |> Objectives.create_step()
    |> case do
      {:ok, step} ->
        create_step_proposed_event!(objective, step, continuation)
        step

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp step_attrs(attrs, objective) do
    attrs
    |> Map.put(:objective_id, objective.id)
    |> Map.put_new(:status, "proposed")
    |> Map.put_new(:stage, "propose_steps")
  end

  defp create_step_proposed_event!(objective, step, continuation) do
    Objectives.create_event(%{
      objective_id: objective.id,
      step_id: step.id,
      kind: "step_proposed",
      summary: "Proposed #{step.kind} objective step.",
      payload: %{
        candidate_action: step.candidate_action,
        provider: step.provider,
        continuation: continuation_summary(continuation)
      }
    })
    |> unwrap_or_rollback()
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp update_hint!(objective, continuation) do
    objective
    |> update_hint(continuation)
    |> case do
      {:ok, objective} -> objective
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp record_cap_impasse(objective, cap_hit, payload) do
    Repo.transaction(fn ->
      blocked =
        objective
        |> Objectives.update_objective(%{
          status: "blocked",
          progress_summary: "#{cap_hit} objective cap reached."
        })
        |> case do
          {:ok, objective} -> objective
          {:error, reason} -> Repo.rollback(reason)
        end

      {:ok, event} =
        Objectives.create_event(%{
          objective_id: blocked.id,
          kind: "impasse",
          summary: "#{cap_hit} reached.",
          payload: Map.put(payload, :cap_hit, cap_hit)
        })

      Commands.emit_objective(:impasse, blocked, %{
        stage: :propose_steps,
        cap_hit: cap_hit,
        trace_id: nil
      })

      Commands.emit_objective(:blocked, blocked, %{
        stage: :propose_steps,
        reason: Atom.to_string(cap_hit),
        trace_id: nil
      })

      %{objective: blocked, steps: [], event: event, impasse: cap_hit, stage: "propose_steps"}
    end)
  end

  defp update_hint(objective, :done),
    do: Objectives.update_objective(objective, %{proposer_hint: nil})

  defp update_hint(objective, {:more, hint}) do
    with {:ok, hint_map} <- Proposer.hint_to_map(hint) do
      Objectives.update_objective(objective, %{proposer_hint: hint_map})
    end
  end

  defp record_no_steps(params, state, reason) do
    case objective_id(params) do
      {:ok, objective_id} ->
        with {:ok, objective} <- Objectives.get_objective(objective_id),
             {:ok, event} <-
               Objectives.create_event(%{
                 objective_id: objective.id,
                 kind: "impasse",
                 summary: "No objective steps were proposed.",
                 payload: %{reason: reason, stage: :propose_steps}
               }) do
          Commands.finish(
            :propose_steps,
            {:ok, %{objective: objective, steps: [], event: event, no_steps_reason: reason}},
            state
          )
        else
          {:error, error} -> Commands.finish(:propose_steps, {:error, error}, state)
        end

      {:error, error} ->
        Commands.finish(:propose_steps, {:error, error}, state)
    end
  end

  defp objective_id(params) do
    case Map.get(params, :objective_id) || Map.get(params, "objective_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_objective_id}
    end
  end

  defp intent_decision(params, objective) do
    decision = Map.get(params, :intent_decision) || Map.get(params, "intent_decision")

    cond do
      is_map(decision) ->
        {:ok, decision}

      text = Map.get(params, :text) || Map.get(params, "text") ->
        {:ok, %{text: text, active_app: objective.active_app}}

      is_binary(objective.source_intent) ->
        {:ok, %{text: objective.source_intent, active_app: objective.active_app}}

      true ->
        {:ok, %{text: objective.objective, active_app: objective.active_app}}
    end
  end

  defp proposer_context(params, context, objective, state) do
    hint =
      Map.get(params, :proposer_hint) || Map.get(params, "proposer_hint") ||
        objective_proposer_hint(objective.proposer_hint) ||
        get_in(state, [:proposer_hints, objective.id])

    %{
      user_id: objective.user_id,
      thread_id: objective.source_thread_id,
      session_id: objective.session_id,
      active_app: objective.active_app,
      objective_id: objective.id,
      text: Map.get(params, :text) || Map.get(params, "text") || objective.source_intent,
      proposer_hint: hint,
      force_stub: Map.get(params, :force_stub) || Map.get(params, "force_stub")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.merge(Map.take(context, [:input_signal_id, :trace_id, :force_stub]))
  end

  defp objective_proposer_hint(nil), do: nil

  defp objective_proposer_hint(hint) when is_binary(hint) do
    case Jason.decode(hint) do
      {:ok, %{} = decoded} -> objective_proposer_hint(decoded)
      _other -> nil
    end
  end

  defp objective_proposer_hint(%{} = hint) do
    case Proposer.normalize_hint(hint) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> nil
    end
  end

  defp objective_proposer_hint(_hint), do: nil

  defp continuation_summary(:done), do: %{status: :done}

  defp continuation_summary({:more, {app_id, state}}),
    do: %{status: :more, app_id: app_id, state: state}

  defp max_steps_per_turn do
    case Settings.get("objectives.max_steps_per_turn") do
      {:ok, value} when is_integer(value) and value > 0 -> value
      _other -> 3
    end
  rescue
    _exception -> 3
  end
end

defmodule AllbertAssist.Objectives.Commands.AuthorizeStep do
  @moduledoc false

  use Jido.Action,
    name: "allbert_objectives_authorize_step",
    description: "Private objective step authorization command."

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Commands
  alias AllbertAssist.Objectives.{Objective, Step}
  alias AllbertAssist.Repo

  @impl true
  def run(params, context) do
    state = Map.get(context, :state, %{})

    with {:ok, step_id} <- step_id(params),
         {:ok, step} <- get_step(step_id),
         {:ok, objective} <- Objectives.get_objective(step.objective_id),
         {:ok, action} <- resolve_action(step),
         {:ok, action_params} <- action_params(step),
         {:ok, result} <- authorize(objective, step, action, action_params, params, context) do
      Commands.finish(:authorize_step, {:ok, result}, state)
    else
      {:error, reason} ->
        Commands.finish(:authorize_step, {:error, reason}, state)
    end
  end

  defp authorize(%Objective{} = objective, %Step{} = step, action, action_params, params, context) do
    Repo.transaction(fn ->
      selected_step =
        step
        |> Objectives.transition_step("selected", %{stage: "authorize_step"})
        |> unwrap_or_rollback()

      _event =
        create_step_event!(
          objective,
          selected_step,
          "step_selected",
          "Objective step selected.",
          %{
            candidate_action: selected_step.candidate_action
          }
        )

      running_objective =
        objective
        |> Objectives.update_objective(%{
          status: "running",
          current_step_id: selected_step.id
        })
        |> unwrap_or_rollback()

      Commands.emit_objective(:step_selected, objective, %{
        stage: :authorize_step,
        step_id: selected_step.id,
        kind: selected_step.kind,
        candidate_action: selected_step.candidate_action,
        trace_id: trace_id(params, context)
      })

      runner_context = runner_context(running_objective, selected_step, params, context)

      action
      |> Runner.run(action_params, runner_context)
      |> handle_runner_result(objective, selected_step, params, context)
    end)
  end

  defp handle_runner_result(
         {:ok, %{status: :needs_confirmation} = response},
         objective,
         step,
         params,
         context
       ) do
    confirmation_id = Map.get(response, :confirmation_id)

    blocked_step =
      step
      |> Objectives.transition_step("blocked", %{
        stage: "authorize_step",
        confirmation_id: confirmation_id,
        trace_id: trace_id(params, context),
        result_summary: "Waiting for confirmation #{confirmation_id}."
      })
      |> unwrap_or_rollback()

    blocked_objective =
      objective
      |> Objectives.update_objective(%{
        status: "blocked",
        current_step_id: blocked_step.id,
        progress_summary: "Waiting for confirmation #{confirmation_id}."
      })
      |> unwrap_or_rollback()

    create_objective_event!(blocked_objective, "blocked", "Objective blocked.", %{
      reason: :confirmation_required,
      confirmation_id: confirmation_id,
      step_id: blocked_step.id
    })

    Commands.emit_objective(:blocked, blocked_objective, %{
      stage: :authorize_step,
      step_id: blocked_step.id,
      reason: "confirmation_required",
      trace_id: trace_id(params, context)
    })

    %{
      objective: blocked_objective,
      step: blocked_step,
      response: response,
      confirmation_id: confirmation_id,
      stage: "authorize_step"
    }
  end

  defp handle_runner_result({:ok, %{status: status} = response}, objective, step, params, context)
       when status in [:completed, :failed, :error] do
    {step_status, signal_kind, event_kind} = terminal_step_status(status)

    finished_step =
      step
      |> Objectives.transition_step(step_status, %{
        stage: "execute_step",
        trace_id: trace_id(params, context),
        result_summary: result_summary(response)
      })
      |> unwrap_or_rollback()

    updated_objective =
      objective
      |> Objectives.update_objective(%{
        status: "running",
        current_step_id: finished_step.id
      })
      |> unwrap_or_rollback()

    create_step_event!(
      updated_objective,
      finished_step,
      event_kind,
      "Objective step #{step_status}.",
      %{status: status, result_summary: result_summary(response)}
    )

    Commands.emit_objective(signal_kind, updated_objective, %{
      stage: :execute_step,
      step_id: finished_step.id,
      result_summary: result_summary(response),
      trace_id: trace_id(params, context)
    })

    %{
      objective: updated_objective,
      step: finished_step,
      response: response,
      stage: "execute_step"
    }
  end

  defp handle_runner_result({:ok, response}, objective, step, params, context) do
    failed_step =
      step
      |> Objectives.transition_step("failed", %{
        stage: "execute_step",
        trace_id: trace_id(params, context),
        result_summary: result_summary(response)
      })
      |> unwrap_or_rollback()

    failed_objective =
      objective
      |> Objectives.update_objective(%{
        status: "failed",
        current_step_id: failed_step.id,
        progress_summary: "Objective step failed during authorization."
      })
      |> unwrap_or_rollback()

    create_step_event!(
      failed_objective,
      failed_step,
      "step_failed",
      "Objective step failed.",
      %{response_status: Map.get(response, :status)}
    )

    Commands.emit_objective(:step_failed, failed_objective, %{
      stage: :authorize_step,
      step_id: failed_step.id,
      error: inspect(Map.get(response, :status, :unknown)),
      trace_id: trace_id(params, context)
    })

    %{objective: failed_objective, step: failed_step, response: response, stage: "authorize_step"}
  end

  defp terminal_step_status(:completed), do: {"completed", :step_completed, "step_completed"}
  defp terminal_step_status(_status), do: {"failed", :step_failed, "step_failed"}

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp create_step_event!(objective, step, kind, summary, payload) do
    Objectives.create_event(%{
      objective_id: objective.id,
      step_id: step.id,
      kind: kind,
      summary: summary,
      payload: payload
    })
    |> unwrap_or_rollback()
  end

  defp create_objective_event!(objective, kind, summary, payload) do
    Objectives.create_event(%{
      objective_id: objective.id,
      kind: kind,
      summary: summary,
      payload: payload
    })
    |> unwrap_or_rollback()
  end

  defp runner_context(objective, step, params, context) do
    Map.merge(context, %{
      user_id: objective.user_id,
      operator_id: objective.user_id,
      thread_id: objective.source_thread_id,
      session_id: objective.session_id,
      active_app: objective.active_app && String.to_existing_atom(objective.active_app),
      objective_id: objective.id,
      step_id: step.id,
      trace_id: trace_id(params, context),
      objective: %{
        id: objective.id,
        title: objective.title,
        status: objective.status
      }
    })
  rescue
    ArgumentError ->
      Map.merge(context, %{
        user_id: objective.user_id,
        operator_id: objective.user_id,
        thread_id: objective.source_thread_id,
        session_id: objective.session_id,
        objective_id: objective.id,
        step_id: step.id,
        trace_id: trace_id(params, context),
        objective: %{id: objective.id, title: objective.title, status: objective.status}
      })
  end

  defp resolve_action(%Step{candidate_action: action}) when is_binary(action) do
    action
    |> action_candidates()
    |> Enum.find_value(fn candidate ->
      case ActionsRegistry.resolve(candidate) do
        {:ok, module} -> {:ok, module}
        {:error, _reason} -> nil
      end
    end)
    |> case do
      nil -> {:error, {:unknown_step_action, action}}
      {:ok, module} -> {:ok, module}
    end
  end

  defp resolve_action(_step), do: {:error, :missing_step_action}

  defp action_candidates(action) do
    modules =
      ActionsRegistry.modules()
      |> Enum.filter(&(inspect(&1) == action))

    modules ++ [action]
  end

  defp action_params(%Step{action_params: nil}), do: {:ok, %{}}
  defp action_params(%Step{action_params: %{} = params}), do: {:ok, params}

  defp action_params(%Step{action_params: params}) when is_binary(params) do
    case Jason.decode(params) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _other -> {:error, :invalid_step_action_params}
    end
  end

  defp action_params(_step), do: {:error, :invalid_step_action_params}

  defp get_step(id) do
    case AllbertAssist.Repo.get(Step, id) do
      %Step{} = step -> {:ok, step}
      nil -> {:error, {:step_not_found, id}}
    end
  end

  defp step_id(params) do
    case Map.get(params, :step_id) || Map.get(params, "step_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_step_id}
    end
  end

  defp trace_id(params, context) do
    Map.get(params, :trace_id) || Map.get(params, "trace_id") || Map.get(context, :trace_id) ||
      Map.get(context, "trace_id")
  end

  defp result_summary(response) do
    summary =
      Map.get(response, :summary) ||
        Map.get(response, "summary") ||
        Map.get(response, :message) ||
        Map.get(response, "message") ||
        inspect(Map.take(response, [:status, :error]))

    if is_binary(summary) and byte_size(summary) > 2_000,
      do: binary_part(summary, 0, 2_000),
      else: summary
  end
end

defmodule AllbertAssist.Objectives.Commands.ExecuteStep do
  @moduledoc false

  use Jido.Action,
    name: "allbert_objectives_execute_step",
    description: "Private objective step execution command."

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Commands
  alias AllbertAssist.Objectives.{Objective, Step}
  alias AllbertAssist.Repo

  @impl true
  def run(params, context) do
    state = Map.get(context, :state, %{})

    with {:ok, step_id} <- step_id(params),
         {:ok, step} <- get_step(step_id),
         {:ok, objective} <- Objectives.get_objective(step.objective_id),
         {:ok, result} <- execute(objective, step, params, context) do
      Commands.finish(:execute_step, {:ok, result}, state)
    else
      {:error, reason} ->
        Commands.finish(:execute_step, {:error, reason}, state)
    end
  end

  defp execute(%Objective{} = objective, %Step{kind: "delegate_agent"} = step, params, context) do
    runner_context =
      Map.merge(context, %{
        user_id: objective.user_id,
        operator_id: objective.user_id,
        thread_id: objective.source_thread_id,
        session_id: objective.session_id,
        objective_id: objective.id,
        step_id: step.id,
        trace_id: trace_id(params, context)
      })

    case Runner.run(
           "delegate_agent",
           %{
             user_id: objective.user_id,
             objective_id: objective.id,
             step_id: step.id,
             delegate_agent_id: step.delegate_agent_id,
             command: "execute",
             params: action_params_or_empty(step)
           },
           runner_context
         ) do
      {:ok, response} ->
        complete_from_result(
          objective,
          step,
          Map.get(response, :status),
          response,
          params,
          context
        )
    end
  end

  defp execute(%Objective{} = objective, %Step{confirmation_id: id} = step, params, context)
       when is_binary(id) and id != "" do
    with {:ok, record} <- Confirmations.read(id),
         :ok <- confirmation_ready(record) do
      status = confirmation_target_status(record)
      target_result = confirmation_target_result(record)
      complete_from_result(objective, step, status, target_result, params, context)
    end
  end

  defp execute(%Objective{} = objective, %Step{} = step, params, context) do
    with {:ok, action} <- resolve_action(step),
         {:ok, action_params} <- action_params(step) do
      runner_context =
        Map.merge(context, %{
          user_id: objective.user_id,
          operator_id: objective.user_id,
          thread_id: objective.source_thread_id,
          session_id: objective.session_id,
          objective_id: objective.id,
          step_id: step.id,
          trace_id: trace_id(params, context)
        })

      case Runner.run(action, action_params, runner_context) do
        {:ok, %{status: :needs_confirmation} = response} ->
          {:error, {:step_requires_confirmation, Map.get(response, :confirmation_id)}}

        {:ok, response} ->
          complete_from_result(
            objective,
            step,
            Map.get(response, :status),
            response,
            params,
            context
          )
      end
    end
  end

  defp complete_from_result(objective, step, status, result, params, context) do
    Repo.transaction(fn ->
      running =
        step
        |> Objectives.transition_step("running", %{
          stage: "execute_step",
          trace_id: trace_id(params, context)
        })
        |> unwrap_or_rollback()

      completed? = normalize_status(status) == :completed
      step_status = if completed?, do: "completed", else: "failed"
      event_kind = if completed?, do: "step_completed", else: "step_failed"
      signal_kind = if completed?, do: :step_completed, else: :step_failed
      result_summary = result_summary(result)

      finished =
        running
        |> Objectives.transition_step(step_status, %{
          stage: "execute_step",
          result_summary: result_summary,
          trace_id: trace_id(params, context)
        })
        |> unwrap_or_rollback()

      updated_objective =
        objective
        |> Objectives.update_objective(%{
          status: if(completed?, do: "running", else: "failed"),
          current_step_id: finished.id,
          progress_summary: result_summary
        })
        |> unwrap_or_rollback()

      _event =
        Objectives.create_event(%{
          objective_id: updated_objective.id,
          step_id: finished.id,
          kind: event_kind,
          summary: "Objective step #{step_status}.",
          payload: %{status: status, result_summary: result_summary}
        })
        |> unwrap_or_rollback()

      Commands.emit_objective(signal_kind, updated_objective, %{
        stage: :execute_step,
        step_id: finished.id,
        result_summary: result_summary,
        trace_id: trace_id(params, context)
      })

      %{
        objective: updated_objective,
        step: finished,
        result: result,
        status: normalize_status(status),
        stage: "execute_step"
      }
    end)
  end

  defp confirmation_ready(%{"status" => "approved"}), do: :ok

  defp confirmation_ready(%{"status" => "pending", "id" => id}),
    do: {:error, {:confirmation_pending, id}}

  defp confirmation_ready(%{"status" => status}),
    do: {:error, {:confirmation_not_approved, status}}

  defp confirmation_target_status(record) do
    record
    |> get_in(["operator_resolution", "target_status"])
    |> normalize_status()
  end

  defp confirmation_target_result(record) do
    get_in(record, ["operator_resolution", "target_result"]) || %{}
  end

  defp normalize_status("completed"), do: :completed
  defp normalize_status(:completed), do: :completed
  defp normalize_status("failed"), do: :failed
  defp normalize_status(:failed), do: :failed
  defp normalize_status("error"), do: :failed
  defp normalize_status(:error), do: :failed
  defp normalize_status(_status), do: :failed

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp resolve_action(%Step{candidate_action: action}) when is_binary(action) do
    action
    |> action_candidates()
    |> Enum.find_value(fn candidate ->
      case ActionsRegistry.resolve(candidate) do
        {:ok, module} -> {:ok, module}
        {:error, _reason} -> nil
      end
    end)
    |> case do
      nil -> {:error, {:unknown_step_action, action}}
      {:ok, module} -> {:ok, module}
    end
  end

  defp resolve_action(_step), do: {:error, :missing_step_action}

  defp action_candidates(action) do
    modules =
      ActionsRegistry.modules()
      |> Enum.filter(&(inspect(&1) == action))

    modules ++ [action]
  end

  defp action_params(%Step{action_params: nil}), do: {:ok, %{}}
  defp action_params(%Step{action_params: %{} = params}), do: {:ok, params}

  defp action_params(%Step{action_params: params}) when is_binary(params) do
    case Jason.decode(params) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _other -> {:error, :invalid_step_action_params}
    end
  end

  defp action_params(_step), do: {:error, :invalid_step_action_params}

  defp action_params_or_empty(step) do
    case action_params(step) do
      {:ok, params} -> params
      {:error, _reason} -> %{}
    end
  end

  defp get_step(id) do
    case Repo.get(Step, id) do
      %Step{} = step -> {:ok, step}
      nil -> {:error, {:step_not_found, id}}
    end
  end

  defp step_id(params) do
    case Map.get(params, :step_id) || Map.get(params, "step_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_step_id}
    end
  end

  defp trace_id(params, context) do
    Map.get(params, :trace_id) || Map.get(params, "trace_id") || Map.get(context, :trace_id) ||
      Map.get(context, "trace_id")
  end

  defp result_summary(result) when is_map(result) do
    summary =
      Map.get(result, :summary) ||
        Map.get(result, "summary") ||
        Map.get(result, :message) ||
        Map.get(result, "message") ||
        inspect(Map.take(result, [:status, "status", :error, "error"]))

    if is_binary(summary) and byte_size(summary) > 2_000,
      do: binary_part(summary, 0, 2_000),
      else: summary
  end

  defp result_summary(result), do: inspect(result)
end

defmodule AllbertAssist.Objectives.Commands.ObserveStep do
  @moduledoc false

  use Jido.Action,
    name: "allbert_objectives_observe_step",
    description: "Private objective observation command."

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Commands
  alias AllbertAssist.Objectives.Evaluator
  alias AllbertAssist.Objectives.{Objective, Step}
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings

  @impl true
  def run(params, context) do
    state = Map.get(context, :state, %{})

    with {:ok, step_id} <- step_id(params),
         {:ok, step} <- get_step(step_id),
         {:ok, objective} <- Objectives.get_objective(step.objective_id),
         {:ok, result} <- observe(objective, step, params, context) do
      Commands.finish(:observe_step, {:ok, result}, state)
    else
      {:error, reason} ->
        Commands.finish(:observe_step, {:error, reason}, state)
    end
  end

  defp observe(%Objective{} = objective, %Step{} = step, params, context) do
    Repo.transaction(fn ->
      summary = observation_summary(step, params)

      observed_step =
        step
        |> Objectives.update_step(%{stage: "observe_step", observation_summary: summary})
        |> unwrap_or_rollback()

      loop_count = (objective.loop_count || 0) + 1
      preliminary_steps = replace_step(Objectives.list_steps(objective.id), observed_step)
      verdict = Evaluator.evaluate(objective, preliminary_steps)
      completed? = verdict == :met
      cap_hit? = verdict == :needs_more_steps and loop_count >= max_loop_count()

      objective_status =
        cond do
          completed? -> "completed"
          cap_hit? -> "blocked"
          true -> "running"
        end

      updated_objective =
        objective
        |> Objectives.update_objective(%{
          status: objective_status,
          current_step_id: observed_step.id,
          loop_count: loop_count,
          last_observation_summary: summary,
          progress_summary: summary,
          completed_at: completed_at(completed?),
          proposer_hint: updated_proposer_hint(objective.proposer_hint, observed_step, verdict)
        })
        |> unwrap_or_rollback()

      _observed =
        Objectives.create_event(%{
          objective_id: updated_objective.id,
          step_id: observed_step.id,
          kind: "observed",
          summary: "Observed objective step result.",
          payload: %{verdict: verdict, observation_summary: summary, loop_count: loop_count}
        })
        |> unwrap_or_rollback()

      Commands.emit_objective(:observed, updated_objective, %{
        stage: :observe_step,
        step_id: observed_step.id,
        observation_summary: summary,
        loop_count: loop_count,
        trace_id: trace_id(params, context)
      })

      if completed? do
        _completed =
          Objectives.create_event(%{
            objective_id: updated_objective.id,
            kind: "completed",
            summary: "Objective acceptance criteria met.",
            payload: %{verdict: verdict, progress_summary: summary}
          })
          |> unwrap_or_rollback()

        Commands.emit_objective(:completed, updated_objective, %{
          stage: :observe_step,
          step_id: observed_step.id,
          completed_at: updated_objective.completed_at,
          progress_summary: summary,
          trace_id: trace_id(params, context)
        })
      end

      if cap_hit? do
        _impasse =
          Objectives.create_event(%{
            objective_id: updated_objective.id,
            kind: "impasse",
            summary: "max_loop_count reached.",
            payload: %{
              cap_hit: :max_loop_count,
              would_have_continued_verdict: verdict,
              loop_count: loop_count
            }
          })
          |> unwrap_or_rollback()

        Commands.emit_objective(:impasse, updated_objective, %{
          stage: :observe_step,
          step_id: observed_step.id,
          cap_hit: :max_loop_count,
          would_have_continued_verdict: verdict,
          trace_id: trace_id(params, context)
        })

        Commands.emit_objective(:blocked, updated_objective, %{
          stage: :observe_step,
          step_id: observed_step.id,
          reason: "max_loop_count",
          trace_id: trace_id(params, context)
        })
      end

      %{
        objective: updated_objective,
        step: observed_step,
        verdict: verdict,
        observation_summary: summary,
        stage: "observe_step"
      }
    end)
  end

  defp replace_step(steps, %Step{id: id} = replacement) do
    Enum.map(steps, fn
      %Step{id: ^id} -> replacement
      step -> step
    end)
  end

  defp completed_at(true), do: DateTime.utc_now()
  defp completed_at(false), do: nil

  defp observation_summary(step, params) do
    explicit = Map.get(params, :observation_summary) || Map.get(params, "observation_summary")

    summary =
      explicit ||
        step.result_summary ||
        "Completed #{step.kind} step #{step.id}."

    if is_binary(summary) and byte_size(summary) > 2_000,
      do: binary_part(summary, 0, 2_000),
      else: summary
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp get_step(id) do
    case Repo.get(Step, id) do
      %Step{} = step -> {:ok, step}
      nil -> {:error, {:step_not_found, id}}
    end
  end

  defp step_id(params) do
    case Map.get(params, :step_id) || Map.get(params, "step_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_step_id}
    end
  end

  defp trace_id(params, context) do
    Map.get(params, :trace_id) || Map.get(params, "trace_id") || Map.get(context, :trace_id) ||
      Map.get(context, "trace_id")
  end

  defp updated_proposer_hint(nil, _step, _verdict), do: nil
  defp updated_proposer_hint(hint, _step, :met), do: hint
  defp updated_proposer_hint(hint, _step, :not_met), do: hint

  defp updated_proposer_hint(hint, step, :needs_more_steps) when is_binary(hint) do
    case Jason.decode(hint) do
      {:ok, %{} = decoded} -> updated_proposer_hint(decoded, step, :needs_more_steps)
      _other -> hint
    end
  end

  defp updated_proposer_hint(%{"state" => %{} = state} = hint, step, :needs_more_steps) do
    completed =
      state
      |> Map.get("completed_steps", [])
      |> List.wrap()
      |> Kernel.++([step.id])
      |> Enum.uniq()

    put_in(hint, ["state", "completed_steps"], completed)
  end

  defp updated_proposer_hint(%{state: %{} = state} = hint, step, :needs_more_steps) do
    completed =
      state
      |> Map.get(:completed_steps, [])
      |> List.wrap()
      |> Kernel.++([step.id])
      |> Enum.uniq()

    put_in(hint, [:state, :completed_steps], completed)
  end

  defp updated_proposer_hint(hint, _step, _verdict), do: hint

  defp max_loop_count do
    case Settings.get("objectives.max_loop_count") do
      {:ok, value} when is_integer(value) and value > 0 -> value
      _other -> 5
    end
  rescue
    _exception -> 5
  end
end

defmodule AllbertAssist.Objectives.Commands.CancelObjective do
  @moduledoc false

  use Jido.Action,
    name: "allbert_objectives_cancel_objective",
    description: "Private objective cancellation command."

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Commands
  alias AllbertAssist.Objectives.{Objective, Step}
  alias AllbertAssist.Repo

  @impl true
  def run(params, context) do
    state = Map.get(context, :state, %{})

    with {:ok, objective_id} <- objective_id(params),
         {:ok, user_id} <- user_id(params, context),
         {:ok, reason} <- reason(params),
         {:ok, objective} <- Objectives.get_objective(user_id, objective_id),
         {:ok, result} <- cancel(objective, reason, params, context) do
      Commands.finish(:cancel_objective, {:ok, result}, state)
    else
      {:error, error} ->
        Commands.finish(:cancel_objective, {:error, error}, state)
    end
  end

  defp cancel(%Objective{status: "cancelled"} = objective, reason, params, context) do
    {:ok,
     %{
       objective: objective,
       steps: Objectives.list_steps(objective.id),
       event: nil,
       reason: reason,
       stage: "cancel_objective",
       already_cancelled?: true,
       trace_id: trace_id(params, context)
     }}
  end

  defp cancel(%Objective{status: "abandoned"}, _reason, _params, _context),
    do: {:error, :objective_abandoned}

  defp cancel(%Objective{} = objective, reason, params, context) do
    Repo.transaction(fn ->
      now = DateTime.utc_now()

      cancelled =
        objective
        |> Objectives.update_objective(%{
          status: "cancelled",
          progress_summary: "Cancelled: #{reason}",
          completed_at: now
        })
        |> unwrap_or_rollback()

      steps =
        objective.id
        |> Objectives.list_steps()
        |> Enum.map(&cancel_step(&1, reason, params, context))

      {:ok, event} =
        Objectives.create_event(%{
          objective_id: cancelled.id,
          kind: "cancelled",
          summary: "Objective cancelled: #{reason}",
          payload: %{
            reason: reason,
            trace_id: trace_id(params, context),
            cancelled_step_count: Enum.count(steps, &(&1.status == "cancelled"))
          }
        })

      Commands.emit_objective(:cancelled, cancelled, %{
        stage: :cancel_objective,
        reason: reason,
        trace_id: trace_id(params, context)
      })

      %{
        objective: cancelled,
        steps: steps,
        event: event,
        reason: reason,
        stage: "cancel_objective",
        trace_id: trace_id(params, context)
      }
    end)
  end

  defp cancel_step(%Step{status: status} = step, _reason, _params, _context)
       when status in ["completed", "failed", "cancelled", "running"],
       do: step

  defp cancel_step(%Step{} = step, reason, params, context) do
    step
    |> Objectives.transition_step("cancelled", %{
      stage: "cancel_objective",
      trace_id: trace_id(params, context),
      result_summary: "Cancelled with objective: #{reason}"
    })
    |> unwrap_or_rollback()
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp objective_id(params) do
    case Map.get(params, :id) || Map.get(params, "id") || Map.get(params, :objective_id) ||
           Map.get(params, "objective_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_objective_id}
    end
  end

  defp user_id(params, context) do
    case Map.get(params, :user_id) || Map.get(params, "user_id") ||
           Map.get(context, :user_id) || Map.get(context, "user_id") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_user_id}
    end
  end

  defp reason(params) do
    case Map.get(params, :reason) || Map.get(params, "reason") do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> {:error, :missing_reason}
          reason -> {:ok, String.slice(reason, 0, 500)}
        end

      _other ->
        {:error, :missing_reason}
    end
  end

  defp trace_id(params, context) do
    Map.get(params, :trace_id) || Map.get(params, "trace_id") || Map.get(context, :trace_id) ||
      Map.get(context, "trace_id")
  end
end
