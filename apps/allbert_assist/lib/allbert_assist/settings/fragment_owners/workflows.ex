defmodule AllbertAssist.Settings.FragmentOwners.Workflows do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "workflows.dir" => %{
      default: "<ALLBERT_HOME>/workflows",
      sensitive?: false,
      type: :string,
      writable?: false
    },
    "workflows.enabled" => %{default: true, sensitive?: false, type: :boolean, writable?: true},
    "workflows.expression_grammar" => %{
      allowed_values: ["closed_v1"],
      default: "closed_v1",
      sensitive?: false,
      type: :enum,
      writable?: false
    },
    "workflows.id_pattern" => %{
      default: "^[a-z0-9][a-z0-9_-]*$",
      sensitive?: false,
      type: :string,
      writable?: false
    },
    "workflows.max_param_bytes_per_step" => %{
      default: 65_536,
      max: 1_048_576,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "workflows.max_steps_per_workflow" => %{
      default: 3,
      max: 10,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "workflows.max_workflows_loaded_per_request" => %{
      default: 8,
      max: 8,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "workflows.max_yaml_bytes_per_file" => %{
      default: 262_144,
      max: 1_048_576,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "workflows.schema_version" => %{
      default: 1,
      max: 1,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: false
    }
  }
  @defaults %{
    "workflows" => %{
      "dir" => "<ALLBERT_HOME>/workflows",
      "enabled" => true,
      "expression_grammar" => "closed_v1",
      "id_pattern" => "^[a-z0-9][a-z0-9_-]*$",
      "max_param_bytes_per_step" => 65_536,
      "max_steps_per_workflow" => 3,
      "max_workflows_loaded_per_request" => 8,
      "max_yaml_bytes_per_file" => 262_144,
      "schema_version" => 1
    }
  }
  @safe_write_keys [
    "workflows.enabled",
    "workflows.max_steps_per_workflow",
    "workflows.max_workflows_loaded_per_request",
    "workflows.max_param_bytes_per_step",
    "workflows.max_yaml_bytes_per_file"
  ]
  @safe_write_rows [
    {251, "workflows.enabled"},
    {252, "workflows.max_steps_per_workflow"},
    {253, "workflows.max_workflows_loaded_per_request"},
    {254, "workflows.max_param_bytes_per_step"},
    {255, "workflows.max_yaml_bytes_per_file"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:workflows",
      owner: "workflows",
      source: :core,
      group: "workflows",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Workflows"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
