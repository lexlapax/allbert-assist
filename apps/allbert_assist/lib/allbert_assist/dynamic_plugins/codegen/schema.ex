defmodule AllbertAssist.DynamicPlugins.Codegen.Schema do
  @moduledoc """
  Structured object schemas for v0.37 dynamic code generation.

  These schemas constrain advisory LLM output before it is written as draft
  evidence. They do not grant trust; generated files still pass source-policy,
  sandbox, trusted validation, and operator confirmation before live use.
  """

  @doc "JSON-schema shape for one read-only action draft generation packet."
  @spec action_draft_schema() :: map()
  def action_draft_schema do
    %{
      type: "object",
      additionalProperties: false,
      properties: %{
        "action_name" => %{type: "string"},
        "description" => %{type: "string"},
        "source" => %{type: "string"},
        "test_source" => %{type: "string"},
        "notes" => %{type: "array", items: %{type: "string"}},
        "usage_units" => %{type: "integer"}
      },
      required: ["description", "source", "test_source"]
    }
  end
end
