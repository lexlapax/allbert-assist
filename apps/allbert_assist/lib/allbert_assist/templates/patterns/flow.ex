defmodule AllbertAssist.Templates.Patterns.Flow do
  @moduledoc """
  Reviewed v0.38 scheduled/chron flow scaffold pattern.

  The generated files describe a schedule and runtime request shape, but do
  not create jobs, enable scheduler policy, or register actions.
  """

  @behaviour AllbertAssist.Templates.Pattern

  alias AllbertAssist.Templates.Parameters

  @impl true
  def id, do: "flow"

  @impl true
  def label, do: "Scheduled flow"

  @impl true
  def description, do: "Reviewed inert scheduled-job and objective-flow blueprint."

  @impl true
  def parameter_schema do
    [
      %{name: "name", type: :string, required: true, min_length: 1, max_length: 64},
      %{
        name: "description",
        type: :string,
        default: "A reviewed scheduled flow scaffold.",
        max_length: 240
      },
      %{
        name: "schedule",
        type: :enum,
        default: "manual",
        allowed_values: ~w[manual daily weekly cron]
      },
      %{name: "at", type: :string, default: "08:00", max_length: 16},
      %{name: "timezone", type: :string, default: "Etc/UTC", max_length: 64},
      %{
        name: "objective",
        type: :string,
        default: "Review the scheduled context.",
        max_length: 240
      }
    ]
  end

  @impl true
  def files do
    [
      %{source: "flow/README.md.tmpl", target: "README.md"},
      %{source: "flow/flow.ex.tmpl", target: "lib/{{module_path}}/flow.ex"},
      %{source: "flow/job_blueprint.json.tmpl", target: "priv/jobs/{{slug}}.json"},
      %{source: "flow/objective_wiring.md.tmpl", target: "docs/objective-wiring.md"}
    ]
  end

  @impl true
  def target_shapes, do: ["job_blueprint", "objective_wiring"]

  @impl true
  def live_integration?, do: false

  @impl true
  def validation_profile, do: "developer_scaffold"

  @impl true
  def normalize_params(params) do
    slug = Map.fetch!(params, "slug")
    module_basename = Parameters.module_basename(slug)
    flow_module = "#{module_basename}.Flow"
    description = Map.get(params, "description", "")
    objective = Map.get(params, "objective", "")
    schedule = Map.get(params, "schedule", "manual")
    timezone = Map.get(params, "timezone", "Etc/UTC")

    {:ok,
     params
     |> Map.put("pattern_id", id())
     |> Map.put("module_path", slug)
     |> Map.put("flow_module", flow_module)
     |> Map.put("schedule_id", "#{slug}_schedule")
     |> Map.put("schedule_literal", inspect(schedule_shape(schedule, params)))
     |> Map.put("schedule_json", Jason.encode!(schedule_shape(schedule, params), pretty: true))
     |> Map.put("job_enabled_json", Jason.encode!(false))
     |> Map.put("json_name", Jason.encode!(slug))
     |> Map.put("json_display_name", Jason.encode!(Map.fetch!(params, "display_name")))
     |> Map.put("json_description", Jason.encode!(description))
     |> Map.put("json_objective", Jason.encode!(objective))
     |> Map.put("json_timezone", Jason.encode!(timezone))
     |> Map.put("timezone_literal", inspect(timezone))
     |> Map.put("description_literal", inspect(description))
     |> Map.put("objective_literal", inspect(objective))}
  end

  defp schedule_shape("daily", params),
    do: %{"kind" => "daily", "at" => Map.get(params, "at", "08:00")}

  defp schedule_shape("weekly", params),
    do: %{"kind" => "weekly", "weekday" => "monday", "at" => Map.get(params, "at", "08:00")}

  defp schedule_shape("cron", _params), do: %{"kind" => "cron", "expression" => "0 8 * * *"}
  defp schedule_shape(_schedule, _params), do: %{"kind" => "manual"}
end
