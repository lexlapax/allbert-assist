defmodule AllbertAssist.PlanBuild do
  @moduledoc """
  Facade for Plan/Build mode.

  Plan/Build is a workspace surface and action family over the v0.24 Objective
  Runtime, not a new runtime loop. M1 establishes the namespace; later v0.44
  milestones add preview contracts, registered actions, and panels.
  """

  alias AllbertAssist.{Confirmations, Maps, Objectives, Workflows}
  alias AllbertAssist.PlanBuild.Runtime
  alias AllbertAssist.Security.PermissionGate

  @spec start_plan_run(map(), map()) :: {:ok, map()} | {:error, term()}
  def start_plan_run(params, context) do
    permission_decision = PermissionGate.authorize(:workflow_run_start, context)

    with {:ok, expanded} <- expand_from_params(params, context) do
      cond do
        approved_confirmation?(context) ->
          execute_plan(params, context, expanded, permission_decision)

        permission_decision.decision == :denied ->
          {:ok, denied(permission_decision)}

        true ->
          create_plan_start_confirmation(params, context, expanded, permission_decision)
      end
    end
  end

  defp execute_plan(params, context, expanded, permission_decision) do
    workflow = expanded.workflow
    preview = expanded.preview
    user_id = field(params, :user_id) || field(context, :user_id) || "local"

    intent_decision = %{
      text: "workflow:#{preview.workflow_id}:#{preview.workflow_version}",
      title: field(params, :title) || preview.objective_title,
      objective: field(params, :title) || preview.objective_title,
      active_app: :allbert,
      parent_objective_id: field(params, :parent_objective_id)
    }

    run_context = Map.put(context, :user_id, user_id)

    with {:ok, %{objective: objective}} <-
           Objectives.frame(intent_decision, run_context),
         {:ok, steps} <- persist_steps(objective.id, expanded.steps),
         {:ok, run_result} <- Runtime.advance(objective.id, run_context) do
      response_status = start_status(run_result.status)

      output_data = %{
        objective_id: objective.id,
        workflow_id: preview.workflow_id,
        workflow_version: preview.workflow_version,
        step_count: length(steps),
        run_status: run_result.status,
        current_step_id: current_step_id(run_result),
        confirmation_id: Map.get(run_result, :confirmation_id),
        preview: json_safe(preview)
      }

      {:ok,
       %{
         message: "Started plan run #{objective.id} for workflow #{workflow["id"]}.",
         status: response_status,
         confirmation_id: Map.get(run_result, :confirmation_id),
         output_data: output_data,
         permission_decision: permission_decision,
         actions: [action(response_status, permission_decision, output_data)]
       }}
    end
  end

  defp persist_steps(objective_id, steps) do
    steps
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, acc} ->
      attrs =
        attrs
        |> Map.put(:objective_id, objective_id)
        |> Map.put_new(:stage, "propose_steps")

      with {:ok, step} <- Objectives.create_step(attrs),
           {:ok, _event} <-
             Objectives.create_event(%{
               objective_id: objective_id,
               step_id: step.id,
               kind: "step_proposed",
               summary: "Proposed #{step.kind} objective step.",
               payload: %{candidate_action: step.candidate_action, provider: step.provider}
             }) do
        {:cont, {:ok, [step | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, steps} -> {:ok, Enum.reverse(steps)}
      error -> error
    end
  end

  defp create_plan_start_confirmation(params, context, expanded, permission_decision) do
    preview = expanded.preview

    attrs = %{
      origin: %{
        actor: field(context, :actor) || "local",
        channel: origin_channel(context, permission_decision)
      },
      target_action: %{
        name: "start_plan_run",
        module: inspect(AllbertAssist.Actions.PlanBuild.StartPlanRun)
      },
      target_permission: :workflow_run_start,
      target_execution_mode: :plan_run_start,
      security_decision: permission_decision,
      params_summary: %{
        workflow_id: preview.workflow_id,
        step_count: preview.step_count,
        authority_gate_count: length(preview.authority_gates),
        preview: json_safe(preview)
      },
      resume_params_ref: params
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        output_data = %{preview: json_safe(preview)}

        {:ok,
         %{
           message: "Plan run requires approval before workflow #{preview.workflow_id} starts.",
           status: :needs_confirmation,
           confirmation_id: confirmation["id"],
           output_data: output_data,
           permission_decision: permission_decision,
           actions: [
             action(:needs_confirmation, permission_decision, %{
               confirmation_id: confirmation["id"],
               workflow_id: preview.workflow_id,
               step_count: preview.step_count
             })
           ]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expand_from_params(params, context) do
    workflow_id = field(params, :workflow_id)
    inputs = field(params, :inputs) || %{}
    Workflows.expand(workflow_id, inputs, context)
  end

  defp denied(permission_decision) do
    %{
      message: permission_decision.reason,
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, %{error: :permission_denied})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "start_plan_run",
      status: status,
      permission: :workflow_run_start,
      permission_decision: permission_decision
    }
    |> Map.merge(metadata)
  end

  defp approved_confirmation?(context) do
    get_in(context, [:confirmation, :approved?]) == true or
      get_in(context, ["confirmation", "approved?"]) == true
  end

  defp start_status(:needs_confirmation), do: :needs_confirmation
  defp start_status(:failed), do: :failed
  defp start_status(:cancelled), do: :cancelled
  defp start_status(_status), do: :completed

  defp current_step_id(%{step: %{id: id}}), do: id
  defp current_step_id(_run_result), do: nil

  # The typed-approval callback verifies the resolver channel against this origin
  # channel; it must reflect the channel the run was requested from, not a default.
  defp origin_channel(context, permission_decision) do
    context
    |> field(:channel)
    |> Kernel.||(permission_decision |> field(:context) |> field(:channel))
    |> normalize_origin_channel()
  end

  defp normalize_origin_channel(%{} = channel),
    do: channel |> field(:name) |> normalize_origin_channel()

  defp normalize_origin_channel(channel) when channel in [nil, :unknown, "unknown"], do: "cli"
  defp normalize_origin_channel(channel) when is_atom(channel), do: Atom.to_string(channel)
  defp normalize_origin_channel(channel) when is_binary(channel), do: channel
  defp normalize_origin_channel(_channel), do: "cli"

  defp field(map, key), do: Maps.field_truthy(map, key)

  defp json_safe(%_struct{} = struct), do: struct |> Map.from_struct() |> json_safe()

  defp json_safe(%{} = map) do
    Map.new(map, fn {key, value} -> {key, json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(value), do: value
end
