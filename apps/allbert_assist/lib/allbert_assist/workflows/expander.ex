defmodule AllbertAssist.Workflows.Expander do
  @moduledoc """
  Lower validated workflow documents into objective step attrs and previews.
  """

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Maps
  alias AllbertAssist.PlanBuild.{Preview, PreviewStep}
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.Policy
  alias AllbertAssist.Workflows.{SchemaError, Validator}

  @spec expand(map(), map(), map()) :: {:ok, map()} | {:error, SchemaError.t()}
  def expand(workflow, inputs \\ %{}, context \\ %{}) do
    with {:ok, resolved_inputs} <- Validator.resolve_inputs(workflow, inputs),
         {:ok, steps} <- expand_steps(workflow, resolved_inputs, context),
         {:ok, preview} <- preview(workflow, resolved_inputs, steps) do
      {:ok,
       %{
         workflow: workflow,
         resolved_inputs: resolved_inputs,
         steps: steps,
         step_count: length(steps),
         preview: preview
       }}
    end
  end

  @spec preview(map(), map(), [map()]) :: {:ok, Preview.t()}
  def preview(workflow, resolved_inputs, step_attrs) do
    steps =
      workflow
      |> Map.get("steps", [])
      |> Enum.with_index(1)
      |> Enum.map(fn {step, ordinal} -> preview_step(step, ordinal) end)

    {:ok,
     %Preview{
       workflow_id: Map.fetch!(workflow, "id"),
       workflow_version: Map.fetch!(workflow, "version"),
       resolved_inputs: Redactor.redact(resolved_inputs),
       objective_title: objective_title(workflow),
       step_count: length(step_attrs),
       steps: steps,
       authority_gates: authority_gates(workflow, steps),
       warnings: []
     }}
  end

  defp expand_steps(workflow, resolved_inputs, context) do
    runtime = %{
      "inputs" => resolved_inputs,
      "workflow" => %{
        "id" => Map.get(workflow, "id"),
        "version" => Map.get(workflow, "version")
      },
      "user" => %{
        "locale" => field(context, :locale) || "en-US",
        "timezone" =>
          field(context, :timezone) || field(context, :operator_timezone) || "America/Los_Angeles"
      }
    }

    workflow
    |> Map.get("steps", [])
    |> Enum.map(&step_attrs(&1, runtime))
    |> then(&{:ok, &1})
  end

  defp step_attrs(%{"kind" => "action"} = step, runtime) do
    %{
      kind: "action",
      provider: "plan_build",
      candidate_action: Map.fetch!(step, "action"),
      action_params: substitute(Map.get(step, "params", %{}), runtime),
      resource_access: %{
        workflow_id: get_in(runtime, ["workflow", "id"]),
        workflow_version: get_in(runtime, ["workflow", "version"]),
        workflow_inputs: Map.get(runtime, "inputs", %{}),
        workflow_step_id: Map.get(step, "id"),
        save_as: Map.get(step, "save_as"),
        confirm_upgrade?: Map.get(step, "confirm") == true,
        on_error: Map.get(step, "on_error", "abort"),
        if: Map.get(step, "if")
      }
    }
  end

  defp step_attrs(%{"kind" => "delegate_agent"} = step, runtime) do
    %{
      kind: "delegate_agent",
      provider: "plan_build",
      delegate_agent_id: Map.fetch!(step, "delegate_agent_id"),
      candidate_action: "delegate_agent",
      action_params: %{
        command: Map.get(step, "command"),
        params: substitute(Map.get(step, "params", %{}), runtime)
      },
      resource_access: %{
        workflow_id: get_in(runtime, ["workflow", "id"]),
        workflow_version: get_in(runtime, ["workflow", "version"]),
        workflow_inputs: Map.get(runtime, "inputs", %{}),
        workflow_step_id: Map.get(step, "id"),
        save_as: Map.get(step, "save_as"),
        confirm_upgrade?: Map.get(step, "confirm") == true,
        on_error: Map.get(step, "on_error", "abort"),
        if: Map.get(step, "if")
      }
    }
  end

  defp step_attrs(%{"kind" => kind} = step, runtime) do
    %{
      kind: kind,
      provider: "plan_build",
      candidate_action: kind,
      action_params:
        substitute(Map.drop(step, ["id", "kind", "save_as", "confirm", "on_error"]), runtime),
      resource_access: %{
        workflow_id: get_in(runtime, ["workflow", "id"]),
        workflow_version: get_in(runtime, ["workflow", "version"]),
        workflow_inputs: Map.get(runtime, "inputs", %{}),
        workflow_step_id: Map.get(step, "id"),
        save_as: Map.get(step, "save_as"),
        confirm_upgrade?: Map.get(step, "confirm") == true,
        on_error: Map.get(step, "on_error", "abort"),
        if: Map.get(step, "if")
      }
    }
  end

  defp preview_step(%{"kind" => "action"} = step, ordinal) do
    action_name = Map.get(step, "action")
    permission = action_permission(action_name)
    safety_floor = Policy.safety_floor(permission)

    %PreviewStep{
      ordinal: ordinal,
      id: Map.get(step, "id"),
      kind: :action,
      action_name: action_name,
      params_summary: Redactor.redact(Map.get(step, "params", %{})),
      permission: permission,
      safety_floor: safety_floor,
      confirmations_required:
        safety_floor == :needs_confirmation or Map.get(step, "confirm") == true,
      confidence_tier: confidence_tier(permission, safety_floor),
      failure_blast_radius: %{halts_at: ordinal, unreachable: []}
    }
  end

  defp preview_step(%{"kind" => "delegate_agent"} = step, ordinal) do
    %PreviewStep{
      ordinal: ordinal,
      id: Map.get(step, "id"),
      kind: :delegate_agent,
      action_name: "delegate_agent",
      params_summary: Redactor.redact(Map.get(step, "params", %{})),
      permission: :objective_write,
      safety_floor: Policy.safety_floor(:objective_write),
      subagent_target: Map.get(step, "delegate_agent_id"),
      confirmations_required: Map.get(step, "confirm") == true,
      failure_blast_radius: %{halts_at: ordinal, unreachable: []}
    }
  end

  defp preview_step(%{"kind" => kind} = step, ordinal) do
    %PreviewStep{
      ordinal: ordinal,
      id: Map.get(step, "id"),
      kind: String.to_atom(kind),
      action_name: kind,
      params_summary: Redactor.redact(Map.drop(step, ["id", "kind"])),
      permission: :read_only,
      safety_floor: Policy.safety_floor(:read_only),
      confirmations_required: Map.get(step, "confirm") == true,
      failure_blast_radius: %{halts_at: ordinal, unreachable: []}
    }
  end

  defp authority_gates(workflow, steps) do
    start_gate = %{
      ordinal: 0,
      gate: :workflow_run_start,
      scope: "workflow://#{Map.fetch!(workflow, "id")}"
    }

    step_gates =
      steps
      |> Enum.filter(& &1.confirmations_required)
      |> Enum.map(fn step ->
        %{
          ordinal: step.ordinal,
          gate: step.permission,
          scope: step.action_name || Atom.to_string(step.kind)
        }
      end)

    [start_gate | step_gates]
  end

  defp action_permission(action_name) do
    case Registry.capability(action_name) do
      {:ok, capability} -> capability.permission
      {:error, _reason} -> :read_only
    end
  end

  defp confidence_tier(_permission, :needs_confirmation), do: :yellow
  defp confidence_tier(:read_only, _floor), do: :green
  defp confidence_tier(_permission, _floor), do: :yellow

  defp objective_title(workflow) do
    workflow
    |> Map.get("description")
    |> case do
      value when is_binary(value) ->
        value |> String.split("\n", parts: 2) |> List.first() |> String.trim()

      _other ->
        Map.fetch!(workflow, "id")
    end
    |> case do
      "" -> Map.fetch!(workflow, "id")
      title -> String.slice(title, 0, 200)
    end
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

  defp resolve_expression("steps." <> _path, _runtime, fallback), do: fallback
  defp resolve_expression(_expression, _runtime, fallback), do: fallback

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

  defp field(map, key), do: Maps.field_truthy(map, key)
end
