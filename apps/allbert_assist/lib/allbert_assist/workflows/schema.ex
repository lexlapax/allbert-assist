defmodule AllbertAssist.Workflows.Schema do
  @moduledoc """
  Workflow YAML schema assembly entrypoint.

  M1 exposes the v1 skeleton so callers and tests can depend on the namespace.
  M2 derives the action-specific branches from the current
  `AllbertAssist.Actions.Registry.modules/0` snapshot at validation time.
  """

  @schema_version 1

  @spec schema_version() :: 1
  def schema_version, do: @schema_version

  @spec json_schema([module()]) :: map()
  def json_schema(_action_modules \\ []) do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "https://allbert.local/schemas/workflows/v1",
      "title" => "Allbert Workflow v1",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["id", "version", "steps"],
      "properties" => %{
        "id" => %{"type" => "string", "pattern" => "^[a-z0-9][a-z0-9_-]*$"},
        "version" => %{"const" => @schema_version},
        "description" => %{"type" => "string", "maxLength" => 2000},
        "owner" => %{"type" => "string"},
        "inputs" => %{"type" => "array"},
        "if" => %{"type" => "string"},
        "steps" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 10,
          "items" => %{"type" => "object"}
        }
      }
    }
  end
end
