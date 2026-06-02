defmodule AllbertAssist.Workflows.Schema do
  @moduledoc """
  Workflow YAML schema assembly entrypoint.

  M1 exposes the v1 skeleton so callers and tests can depend on the namespace.
  M2 derives the action-specific branches from the current
  `AllbertAssist.Actions.Registry.modules/0` snapshot at validation time.
  """

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Objectives.Step

  @schema_version 1
  @step_id_pattern "^[a-z][a-z0-9_]*$"
  @workflow_id_pattern "^[a-z0-9][a-z0-9_-]*$"

  @spec schema_version() :: 1
  def schema_version, do: @schema_version

  @spec json_schema([module()]) :: map()
  def json_schema(action_modules \\ Registry.modules()) do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "https://allbert.local/schemas/workflows/v1",
      "title" => "Allbert Workflow v1",
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["id", "version", "steps"],
      "properties" => %{
        "id" => %{"type" => "string", "pattern" => @workflow_id_pattern},
        "version" => %{"const" => @schema_version},
        "description" => %{"type" => "string", "maxLength" => 2000},
        "owner" => %{"type" => "string"},
        "inputs" => %{
          "type" => "array",
          "items" => input_schema()
        },
        "if" => %{"type" => "string"},
        "steps" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 10,
          "items" => step_schema(action_modules)
        }
      }
    }
  end

  @spec root([module()]) :: JSV.Root.t()
  def root(action_modules \\ Registry.modules()), do: JSV.build!(json_schema(action_modules))

  @spec action_param_schema(module()) :: map()
  def action_param_schema(action_module) when is_atom(action_module) do
    properties =
      action_module
      |> action_schema()
      |> Enum.map(fn {key, opts} -> {Atom.to_string(key), param_schema(opts)} end)
      |> Map.new()

    required =
      action_module
      |> action_schema()
      |> Enum.filter(fn {_key, opts} -> Keyword.get(opts, :required, false) == true end)
      |> Enum.map(fn {key, _opts} -> Atom.to_string(key) end)

    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => properties,
      "required" => required
    }
  end

  @spec action_schema(module()) :: keyword()
  def action_schema(action_module) do
    if function_exported?(action_module, :schema, 0), do: action_module.schema(), else: []
  end

  @spec action_names([module()]) :: [String.t()]
  def action_names(action_modules \\ Registry.modules()) do
    Enum.map(action_modules, & &1.name())
  end

  defp input_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["name", "type"],
      "properties" => %{
        "name" => %{"type" => "string", "pattern" => @step_id_pattern},
        "type" => %{"enum" => ["string", "integer", "number", "boolean"]},
        "required" => %{"type" => "boolean"},
        "default" => %{},
        "description" => %{"type" => "string", "maxLength" => 500}
      }
    }
  end

  defp step_schema(action_modules) do
    %{
      "oneOf" => [
        action_step_schema(action_modules),
        ask_user_step_schema(),
        wait_step_schema(),
        observe_step_schema(),
        reflect_step_schema(),
        delegate_agent_step_schema()
      ]
    }
  end

  defp common_properties do
    %{
      "id" => %{"type" => "string", "pattern" => @step_id_pattern},
      "kind" => %{"enum" => Step.kinds()},
      "if" => %{"type" => "string"},
      "save_as" => %{"type" => "string", "pattern" => @step_id_pattern},
      "confirm" => %{"type" => "boolean"},
      "on_error" => %{"enum" => ["abort", "continue"]}
    }
  end

  defp base_step_schema(kind, extra_properties, required) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["id", "kind"] ++ required,
      "properties" =>
        Map.merge(common_properties(), extra_properties) |> put_in(["kind"], %{"const" => kind})
    }
  end

  defp action_step_schema(action_modules) do
    per_action =
      Enum.map(action_modules, fn module ->
        %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["id", "kind", "action"],
          "properties" =>
            common_properties()
            |> Map.merge(%{
              "kind" => %{"const" => "action"},
              "action" => %{"const" => module.name()},
              "params" => action_param_schema(module)
            })
        }
      end)

    %{"oneOf" => per_action}
  end

  defp ask_user_step_schema do
    base_step_schema(
      "ask_user",
      %{
        "prompt" => %{"type" => "string", "maxLength" => 2000},
        "options" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["value", "label"],
            "properties" => %{
              "value" => %{"type" => "string"},
              "label" => %{"type" => "string"}
            }
          }
        }
      },
      ["prompt"]
    )
  end

  defp wait_step_schema do
    base_step_schema(
      "wait",
      %{
        "until" => %{"type" => "string"},
        "for_ms" => %{"type" => "integer", "minimum" => 1, "maximum" => 600_000},
        "match" => %{"type" => "object"}
      },
      []
    )
  end

  defp observe_step_schema do
    base_step_schema(
      "observe",
      %{"signal" => %{"type" => "string"}, "match" => %{"type" => "object"}},
      ["signal"]
    )
  end

  defp reflect_step_schema do
    base_step_schema(
      "reflect",
      %{"prompt" => %{"type" => "string"}, "inputs" => %{"type" => "array"}},
      ["prompt"]
    )
  end

  defp delegate_agent_step_schema do
    base_step_schema(
      "delegate_agent",
      %{
        "delegate_agent_id" => %{"type" => "string"},
        "command" => %{"type" => "string"},
        "params" => %{"type" => "object"}
      },
      ["delegate_agent_id", "command"]
    )
  end

  defp param_schema(opts) do
    opts
    |> Keyword.get(:type)
    |> param_schema_for_type()
  end

  defp param_schema_for_type(:string), do: %{"type" => "string"}
  defp param_schema_for_type(:integer), do: %{"type" => "integer"}
  defp param_schema_for_type(:float), do: %{"type" => "number"}
  defp param_schema_for_type(:number), do: %{"type" => "number"}
  defp param_schema_for_type(:boolean), do: %{"type" => "boolean"}
  defp param_schema_for_type(:map), do: %{"type" => "object"}

  defp param_schema_for_type({:list, :map}),
    do: %{"type" => "array", "items" => %{"type" => "object"}}

  defp param_schema_for_type({:list, :string}),
    do: %{"type" => "array", "items" => %{"type" => "string"}}

  defp param_schema_for_type({:list, _type}), do: %{"type" => "array"}
  defp param_schema_for_type(:atom), do: %{"type" => "string"}
  defp param_schema_for_type(:any), do: %{}
  defp param_schema_for_type(_type), do: %{}
end
