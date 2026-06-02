defmodule AllbertAssist.PlanBuild.Runtime do
  @moduledoc """
  Plan/Build-aware advancement over the v0.24 Objective Runtime.

  This is a plain module because it owns no durable state. It selects the next
  persisted Plan/Build step, applies workflow-only metadata, and delegates step
  execution to the existing Objective engine and `Actions.Runner.run/3` path.
  """

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.{Engine, Objective, Step}
  alias AllbertAssist.Security.PermissionGate

  @default_step_limit 25
  @plan_step_confirm_action "plan_step_confirm"

  @spec advance(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def advance(objective_id, context \\ %{}, opts \\ [])

  def advance(objective_id, context, opts)
      when is_binary(objective_id) and is_map(context) do
    limit = Keyword.get(opts, :max_steps, @default_step_limit)

    with {:ok, objective} <- objective(objective_id, context) do
      do_advance(objective, context, limit, [])
    end
  end

  def advance(_objective_id, _context, _opts), do: {:error, :missing_objective_id}

  @spec plan_step_confirm_action() :: String.t()
  def plan_step_confirm_action, do: @plan_step_confirm_action

  defp do_advance(_objective, _context, 0, advanced) do
    {:ok,
     %{
       status: :step_limit_reached,
       message: "Plan run paused after reaching the per-call step limit.",
       advanced_steps: Enum.reverse(advanced)
     }}
  end

  defp do_advance(%Objective{} = objective, context, remaining, advanced) do
    with {:ok, objective} <- Objectives.get_objective(objective.id) do
      cond do
        objective.status == "cancelled" ->
          {:ok, terminal(:cancelled, objective, advanced)}

        objective.status == "failed" ->
          {:ok, terminal(:failed, objective, advanced)}

        objective.status == "completed" ->
          {:ok, terminal(:completed, objective, advanced)}

        blocked = blocked_current_step(objective) ->
          continue_blocked_step(blocked, objective, context, remaining, advanced)

        running_step?(objective) ->
          {:ok, terminal(:running, objective, advanced)}

        step = next_proposed_step(objective) ->
          advance_step(step, objective, context, remaining, advanced)

        true ->
          complete_plan(objective, advanced)
      end
    end
  end

  defp advance_step(%Step{} = step, objective, context, remaining, advanced) do
    cond do
      not if_condition_met?(step) ->
        with {:ok, skipped} <- skip_step(step, context) do
          do_advance(objective, context, remaining - 1, [skipped | advanced])
        end

      step.kind == "ask_user" ->
        block_for_confirmation(step, objective, :objective_write, context, advanced)

      confirm_upgrade?(step) ->
        block_for_confirmation(step, objective, step_permission(step), context, advanced)

      true ->
        run_step(step, objective, context, remaining, advanced)
    end
  end

  defp run_step(%Step{} = step, objective, context, remaining, advanced) do
    with {:ok, step} <- resolve_step_params(step, objective),
         {:ok, result} <-
           Engine.Agent.authorize_step(%{step_id: step.id, trace_id: trace_id(context)}) do
      result_step = Map.get(result, :step)
      result_objective = Map.get(result, :objective, objective)
      response = Map.get(result, :response, %{})

      cond do
        Map.get(response, :status) == :needs_confirmation ->
          {:ok, needs_confirmation(result_objective, result_step, response, advanced)}

        match?(%Step{status: "failed"}, result_step) and on_error(result_step) == "continue" ->
          do_advance(result_objective, context, remaining - 1, [result_step | advanced])

        match?(%Step{status: "failed"}, result_step) ->
          fail_plan(result_objective, result_step, advanced)

        true ->
          do_advance(result_objective, context, remaining - 1, [result_step | advanced])
      end
    end
  end

  defp continue_blocked_step(%Step{} = step, objective, context, remaining, advanced) do
    case confirmation_status(step.confirmation_id) do
      "approved" ->
        continue_approved_step(step, objective, context, remaining, advanced)

      "pending" ->
        {:ok,
         needs_confirmation(objective, step, %{confirmation_id: step.confirmation_id}, advanced)}

      status ->
        {:error, {:confirmation_not_approved, status}}
    end
  end

  defp continue_approved_step(step, objective, context, remaining, advanced) do
    with {:ok, step} <-
           Objectives.update_step(step, %{
             status: "proposed",
             stage: "propose_steps",
             confirmation_id: nil,
             result_summary: nil
           }),
         {:ok, objective} <-
           Objectives.update_objective(objective, %{
             status: "running",
             current_step_id: nil,
             progress_summary: "Plan step confirmation approved."
           }) do
      continue_approved_step_execution(step, objective, context, remaining, advanced)
    end
  end

  defp continue_approved_step_execution(
         %Step{kind: "ask_user"} = step,
         objective,
         context,
         remaining,
         advanced
       ) do
    complete_confirmed_ask_user(step, objective, context, remaining, advanced)
  end

  defp continue_approved_step_execution(step, objective, context, remaining, advanced) do
    run_step(step, objective, context, remaining, advanced)
  end

  defp complete_confirmed_ask_user(step, objective, context, remaining, advanced) do
    with {:ok, completed} <-
           Objectives.transition_step(step, "completed", %{
             stage: "execute_step",
             trace_id: trace_id(context),
             result_summary: "Operator approved checkpoint #{step.confirmation_id || step.id}."
           }),
         {:ok, _event} <-
           Objectives.create_event(%{
             objective_id: objective.id,
             step_id: completed.id,
             kind: "step_completed",
             summary: "Plan checkpoint completed.",
             payload: %{workflow_step_id: workflow_step_id(completed)}
           }) do
      do_advance(objective, context, remaining - 1, [completed | advanced])
    end
  end

  defp block_for_confirmation(step, objective, permission, context, advanced) do
    permission_decision = step_confirmation_decision(permission)

    attrs = %{
      origin: %{
        actor: field(context, :actor) || field(context, :user_id) || "local",
        channel: field(context, :channel) || "cli",
        user_id: objective.user_id
      },
      target_action: %{
        name: @plan_step_confirm_action,
        module: inspect(__MODULE__)
      },
      target_permission: permission,
      target_execution_mode: :plan_step_confirm,
      security_decision: permission_decision,
      params_summary: %{
        objective_id: objective.id,
        step_id: step.id,
        workflow_step_id: workflow_step_id(step),
        action: step.candidate_action || step.kind
      },
      resume_params_ref: %{
        objective_id: objective.id,
        step_id: step.id,
        user_id: objective.user_id
      }
    }

    with {:ok, confirmation} <- Confirmations.create(attrs),
         {:ok, blocked_step} <-
           Objectives.transition_step(step, "blocked", %{
             stage: "authorize_step",
             confirmation_id: confirmation["id"],
             trace_id: trace_id(context),
             result_summary: "Waiting for Plan/Build step confirmation #{confirmation["id"]}."
           }),
         {:ok, blocked_objective} <-
           Objectives.update_objective(objective, %{
             status: "blocked",
             current_step_id: blocked_step.id,
             progress_summary: "Waiting for Plan/Build step confirmation #{confirmation["id"]}."
           }),
         {:ok, _event} <-
           Objectives.create_event(%{
             objective_id: blocked_objective.id,
             step_id: blocked_step.id,
             kind: "blocked",
             summary: "Plan step blocked for confirmation.",
             payload: %{
               confirmation_id: confirmation["id"],
               workflow_step_id: workflow_step_id(blocked_step)
             }
           }) do
      {:ok,
       needs_confirmation(
         blocked_objective,
         blocked_step,
         %{confirmation_id: confirmation["id"]},
         advanced
       )}
    end
  end

  defp skip_step(step, context) do
    with {:ok, skipped} <-
           Objectives.transition_step(step, "skipped", %{
             stage: "execute_step",
             trace_id: trace_id(context),
             result_summary: "Skipped by workflow if condition."
           }),
         {:ok, _event} <-
           Objectives.create_event(%{
             objective_id: skipped.objective_id,
             step_id: skipped.id,
             kind: "observed",
             summary: "Plan step skipped by workflow if condition.",
             payload: %{workflow_step_id: workflow_step_id(skipped)}
           }) do
      {:ok, skipped}
    end
  end

  defp fail_plan(objective, step, advanced) do
    with {:ok, failed} <-
           Objectives.update_objective(objective, %{
             status: "failed",
             current_step_id: step.id,
             progress_summary: step.result_summary || "Plan step failed."
           }),
         {:ok, _event} <-
           Objectives.create_event(%{
             objective_id: failed.id,
             step_id: step.id,
             kind: "failed",
             summary: "Plan run failed.",
             payload: %{workflow_step_id: workflow_step_id(step)}
           }) do
      {:ok, terminal(:failed, failed, [step | advanced])}
    end
  end

  defp complete_plan(objective, advanced) do
    with {:ok, completed} <-
           Objectives.update_objective(objective, %{
             status: "completed",
             current_step_id: nil,
             completed_at: DateTime.utc_now(),
             progress_summary: "Plan run completed."
           }),
         {:ok, _event} <-
           Objectives.create_event(%{
             objective_id: completed.id,
             kind: "completed",
             summary: "Plan run completed.",
             payload: %{advanced_step_count: length(advanced)}
           }) do
      {:ok, terminal(:completed, completed, advanced)}
    end
  end

  defp resolve_step_params(%Step{kind: "action"} = step, objective) do
    with {:ok, params} <- decode_map(step.action_params),
         resolved <- substitute(params, runtime_for_step(step, objective)) do
      if resolved == params do
        {:ok, step}
      else
        Objectives.update_step(step, %{action_params: resolved})
      end
    end
  end

  defp resolve_step_params(step, _objective), do: {:ok, step}

  defp runtime_for_step(step, objective) do
    access = resource_access(step)

    %{
      "inputs" => Map.get(access, "workflow_inputs", %{}),
      "workflow" => %{
        "id" => Map.get(access, "workflow_id"),
        "version" => Map.get(access, "workflow_version")
      },
      "user" => %{"locale" => "en-US", "timezone" => "America/Los_Angeles"},
      "steps" => completed_step_outputs(objective.id)
    }
  end

  defp completed_step_outputs(objective_id) do
    objective_id
    |> Objectives.list_steps()
    |> Enum.filter(&(&1.status in ["completed", "skipped", "failed"]))
    |> Enum.reduce(%{}, fn step, acc ->
      access = resource_access(step)

      case Map.get(access, "workflow_step_id") do
        id when is_binary(id) and id != "" ->
          value = step.result_summary || step.observation_summary || ""
          save_as = Map.get(access, "save_as")

          output =
            %{"value" => value, "result_summary" => value}
            |> maybe_put(save_as, value)

          Map.put(acc, id, output)

        _other ->
          acc
      end
    end)
  end

  defp substitute(%{} = map, runtime) do
    Map.new(map, fn {key, value} -> {key, substitute(value, runtime)} end)
  end

  defp substitute(list, runtime) when is_list(list), do: Enum.map(list, &substitute(&1, runtime))

  defp substitute(value, runtime) when is_binary(value) do
    case Regex.run(~r/^\$\{([^}]+)\}$/, value, capture: :all_but_first) do
      [expression] -> resolve_expression(String.trim(expression), runtime, value)
      _other -> replace_embedded(value, runtime)
    end
  end

  defp substitute(value, _runtime), do: value

  defp replace_embedded(value, runtime) do
    Regex.replace(~r/\$\{([^}]+)\}/, value, fn _match, expression ->
      expression
      |> String.trim()
      |> resolve_expression(runtime, "${#{expression}}")
      |> to_string()
    end)
  end

  defp resolve_expression("inputs." <> path, runtime, fallback),
    do: get_path(runtime["inputs"], path, fallback)

  defp resolve_expression("workflow." <> path, runtime, fallback),
    do: get_path(runtime["workflow"], path, fallback)

  defp resolve_expression("user." <> path, runtime, fallback),
    do: get_path(runtime["user"], path, fallback)

  defp resolve_expression("steps." <> path, runtime, fallback),
    do: get_path(runtime["steps"], path, fallback)

  defp resolve_expression(_expression, _runtime, fallback), do: fallback

  defp if_condition_met?(step) do
    case Map.get(resource_access(step), "if") do
      nil -> true
      "" -> true
      value -> truthy_expression?(value, runtime_for_condition(step))
    end
  end

  defp runtime_for_condition(step) do
    access = resource_access(step)

    %{
      "inputs" => Map.get(access, "workflow_inputs", %{}),
      "workflow" => %{
        "id" => Map.get(access, "workflow_id"),
        "version" => Map.get(access, "workflow_version")
      },
      "user" => %{"locale" => "en-US", "timezone" => "America/Los_Angeles"},
      "steps" => %{}
    }
  end

  defp truthy_expression?(value, runtime) when is_binary(value) do
    expression =
      case Regex.run(~r/^\$\{([^}]+)\}$/, value, capture: :all_but_first) do
        [expression] -> String.trim(expression)
        _other -> String.trim(value)
      end

    cond do
      expression in ["true", "TRUE"] ->
        true

      expression in ["false", "FALSE"] ->
        false

      String.contains?(expression, "==") ->
        [left, right] = String.split(expression, "==", parts: 2)
        compare_value(left, runtime) == compare_value(right, runtime)

      String.contains?(expression, "!=") ->
        [left, right] = String.split(expression, "!=", parts: 2)
        compare_value(left, runtime) != compare_value(right, runtime)

      true ->
        truthy?(resolve_expression(expression, runtime, false))
    end
  end

  defp truthy_expression?(value, _runtime), do: truthy?(value)

  defp compare_value(value, runtime) do
    value = String.trim(value)

    cond do
      value =~ ~r/^".*"$/ or value =~ ~r/^'.*'$/ ->
        value |> String.trim("\"") |> String.trim("'")

      value in ["true", "false"] ->
        value == "true"

      Regex.match?(~r/^\d+$/, value) ->
        String.to_integer(value)

      String.starts_with?(value, "inputs.") or String.starts_with?(value, "workflow.") or
          String.starts_with?(value, "user.") ->
        resolve_expression(value, runtime, value)

      true ->
        value
    end
  end

  defp next_proposed_step(objective) do
    objective.id
    |> Objectives.list_steps()
    |> Enum.find(&(&1.provider == "plan_build" and &1.status == "proposed"))
  end

  defp blocked_current_step(%Objective{current_step_id: id}) when is_binary(id) and id != "" do
    id
    |> step_by_id()
    |> case do
      %Step{provider: "plan_build", status: "blocked"} = step -> step
      _other -> nil
    end
  end

  defp blocked_current_step(%Objective{} = objective) do
    objective.id
    |> Objectives.list_steps()
    |> Enum.find(&(&1.provider == "plan_build" and &1.status == "blocked"))
  end

  defp running_step?(%Objective{} = objective) do
    objective.id
    |> Objectives.list_steps()
    |> Enum.any?(&(&1.provider == "plan_build" and &1.status == "running"))
  end

  defp objective(objective_id, context) do
    case field(context, :user_id) do
      user_id when is_binary(user_id) and user_id != "" ->
        Objectives.get_objective(user_id, objective_id)

      _other ->
        Objectives.get_objective(objective_id)
    end
  end

  defp step_by_id(id) do
    AllbertAssist.Repo.get(Step, id)
  end

  defp needs_confirmation(objective, step, response, advanced) do
    %{
      status: :needs_confirmation,
      message: "Plan run #{objective.id} is waiting for confirmation.",
      objective: objective,
      step: step,
      confirmation_id: Map.get(response, :confirmation_id),
      advanced_steps: Enum.reverse(advanced)
    }
  end

  defp terminal(status, objective, advanced) do
    %{
      status: status,
      message: "Plan run #{objective.id} is #{status}.",
      objective: objective,
      advanced_steps: Enum.reverse(advanced)
    }
  end

  defp step_permission(step) do
    with action when is_binary(action) <- step.candidate_action,
         {:ok, capability} <- Registry.capability(action) do
      capability.permission
    else
      _other -> :objective_write
    end
  end

  defp step_confirmation_decision(permission) do
    permission
    |> PermissionGate.authorize(%{})
    |> Map.merge(%{
      decision: :needs_confirmation,
      requires_confirmation: true,
      reason: "Workflow step confirmation upgrade required."
    })
  end

  defp confirmation_status(id) when is_binary(id) and id != "" do
    case Confirmations.read(id) do
      {:ok, %{"status" => status}} -> status
      {:error, reason} -> inspect(reason)
    end
  end

  defp confirmation_status(_id), do: "missing"

  defp confirm_upgrade?(step), do: Map.get(resource_access(step), "confirm_upgrade?") == true
  defp on_error(step), do: Map.get(resource_access(step), "on_error", "abort")
  defp workflow_step_id(step), do: Map.get(resource_access(step), "workflow_step_id")

  defp resource_access(%Step{resource_access: %{} = access}), do: stringify_keys(access)

  defp resource_access(%Step{resource_access: access}) when is_binary(access) do
    case Jason.decode(access) do
      {:ok, %{} = decoded} -> decoded
      _other -> %{}
    end
  end

  defp resource_access(_step), do: %{}

  defp decode_map(nil), do: {:ok, %{}}
  defp decode_map(%{} = map), do: {:ok, map}

  defp decode_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _other -> {:error, :invalid_step_action_params}
    end
  end

  defp decode_map(_value), do: {:error, :invalid_step_action_params}

  defp get_path(map, path, fallback) do
    path
    |> String.split(".")
    |> Enum.reduce_while(map, fn key, acc ->
      case acc do
        %{} -> {:cont, Map.get(acc, key)}
        _other -> {:halt, nil}
      end
    end)
    |> case do
      nil -> fallback
      value -> value
    end
  end

  defp stringify_keys(%{} = map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_keys(value)}
      {key, value} -> {to_string(key), stringify_keys(value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp maybe_put(map, nil, _value), do: map
  defp maybe_put(map, "", _value), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp trace_id(context), do: field(context, :trace_id)

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil
end
