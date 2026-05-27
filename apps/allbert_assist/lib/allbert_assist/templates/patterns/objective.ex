defmodule AllbertAssist.Templates.Patterns.Objective do
  @moduledoc """
  Reviewed v0.38 objective-workflow scaffold pattern.

  The output is an inert workflow blueprint. It does not create objectives,
  objective steps, jobs, or private goal loops.
  """

  @behaviour AllbertAssist.Templates.Pattern

  alias AllbertAssist.Templates.Parameters

  @impl true
  def id, do: "objective"

  @impl true
  def label, do: "Objective workflow"

  @impl true
  def description, do: "Reviewed inert multi-step objective workflow blueprint."

  @impl true
  def parameter_schema do
    [
      %{name: "name", type: :string, required: true, min_length: 1, max_length: 64},
      %{
        name: "description",
        type: :string,
        default: "A reviewed objective workflow scaffold.",
        max_length: 240
      },
      %{
        name: "objective",
        type: :string,
        default: "Complete the reviewed workflow.",
        max_length: 240
      },
      %{
        name: "steps",
        type: :string,
        default: "Frame the request|Collect context|Propose next action|Ask for approval",
        max_length: 500
      }
    ]
  end

  @impl true
  def files do
    [
      %{source: "objective/README.md.tmpl", target: "README.md"},
      %{source: "objective/objective.ex.tmpl", target: "lib/{{module_path}}/objective.ex"},
      %{source: "objective/workflow.json.tmpl", target: "priv/objectives/{{slug}}.json"},
      %{
        source: "objective/confirmation-boundary.md.tmpl",
        target: "docs/confirmation-boundary.md"
      }
    ]
  end

  @impl true
  def target_shapes, do: ["objective_workflow", "objective_steps"]

  @impl true
  def live_integration?, do: false

  @impl true
  def validation_profile, do: "developer_scaffold"

  @impl true
  def normalize_params(params) do
    slug = Map.fetch!(params, "slug")
    module_basename = Parameters.module_basename(slug)
    objective_module = "#{module_basename}.Objective"
    description = Map.get(params, "description", "")
    objective = Map.get(params, "objective", "")
    steps = steps(Map.get(params, "steps", ""))

    {:ok,
     params
     |> Map.put("pattern_id", id())
     |> Map.put("module_path", slug)
     |> Map.put("objective_module", objective_module)
     |> Map.put("workflow_id", "#{slug}_workflow")
     |> Map.put("steps_literal", inspect(steps))
     |> Map.put("steps_json", Jason.encode!(steps, pretty: true))
     |> Map.put("json_display_name", Jason.encode!(Map.fetch!(params, "display_name")))
     |> Map.put("json_description", Jason.encode!(description))
     |> Map.put("json_objective", Jason.encode!(objective))
     |> Map.put("description_literal", inspect(description))
     |> Map.put("objective_literal", inspect(objective))}
  end

  defp steps(value) when is_binary(value) do
    value
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp steps(_value), do: []
end
