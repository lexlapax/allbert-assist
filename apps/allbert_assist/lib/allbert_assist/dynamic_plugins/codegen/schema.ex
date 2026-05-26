defmodule AllbertAssist.DynamicPlugins.Codegen.Schema do
  @moduledoc """
  Structured object schemas for v0.37 dynamic code generation.

  These schemas constrain advisory LLM output before it is written as draft
  evidence. They do not grant trust; generated files still pass source-policy,
  sandbox, trusted validation, and operator confirmation before live use.
  """

  @doc "JSON-schema shape for one action draft generation packet."
  def action_draft_schema do
    author_schema()
    |> put_in([:properties, "test_source"], %{type: "string"})
    |> update_in([:required], &(&1 ++ ["test_source"]))
  end

  @doc "JSON-schema shape for role-specific generation packets."
  def role_schema(:planner), do: planner_schema()
  def role_schema(:author), do: author_schema()
  def role_schema(:trial_author), do: trial_author_schema()
  def role_schema(:critic), do: critic_schema()
  def role_schema(:repair), do: repair_schema()

  defp planner_schema do
    %{
      type: "object",
      additionalProperties: false,
      properties: %{
        "target_shape" => %{type: "string"},
        "permission_ceiling" => %{type: "string"},
        "summary" => %{type: "string"},
        "acceptance_criteria" => %{type: "array", items: %{type: "string"}},
        "constraints" => %{type: "array", items: %{type: "string"}},
        "test_strategy" => %{type: "string"},
        "notes" => %{type: "array", items: %{type: "string"}},
        "usage_units" => %{type: "integer"}
      },
      required: [
        "target_shape",
        "permission_ceiling",
        "summary",
        "acceptance_criteria",
        "constraints",
        "test_strategy",
        "notes",
        "usage_units"
      ]
    }
  end

  defp author_schema do
    %{
      type: "object",
      additionalProperties: false,
      properties: %{
        "action_name" => %{type: "string"},
        "description" => %{type: "string"},
        "source" => %{type: "string"},
        "notes" => %{type: "array", items: %{type: "string"}},
        "usage_units" => %{type: "integer"}
      },
      required: ["action_name", "description", "source", "notes", "usage_units"]
    }
  end

  defp trial_author_schema do
    %{
      type: "object",
      additionalProperties: false,
      properties: %{
        "test_source" => %{type: "string"},
        "focused_test_paths" => %{type: "array", items: %{type: "string"}},
        "notes" => %{type: "array", items: %{type: "string"}},
        "usage_units" => %{type: "integer"}
      },
      required: ["test_source", "focused_test_paths", "notes", "usage_units"]
    }
  end

  defp critic_schema do
    %{
      type: "object",
      additionalProperties: false,
      properties: %{
        "verdict" => %{type: "string", enum: ["accepted", "repair_requested", "rejected"]},
        "findings" => %{type: "array", items: %{type: "string"}},
        "repair_instructions" => %{type: "string"},
        "notes" => %{type: "array", items: %{type: "string"}},
        "usage_units" => %{type: "integer"}
      },
      required: ["verdict", "findings", "repair_instructions", "notes", "usage_units"]
    }
  end

  defp repair_schema do
    %{
      type: "object",
      additionalProperties: false,
      properties: %{
        "status" => %{type: "string", enum: ["not_needed", "repaired", "unable"]},
        "action_name" => %{type: "string"},
        "description" => %{type: "string"},
        "source" => %{type: "string"},
        "test_source" => %{type: "string"},
        "notes" => %{type: "array", items: %{type: "string"}},
        "usage_units" => %{type: "integer"}
      },
      required: [
        "status",
        "action_name",
        "description",
        "source",
        "test_source",
        "notes",
        "usage_units"
      ]
    }
  end
end
