defmodule AllbertAssist.Settings.FragmentOwners.DynamicCodegen do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "dynamic_codegen.allowed_action_permissions" => %{
      default: ["read_only"],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "dynamic_codegen.allowed_facades" => %{
      default: [],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "dynamic_codegen.allowed_targets" => %{
      default: ["action"],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "dynamic_codegen.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "dynamic_codegen.integration_approval_surfaces" => %{
      default: ["cli", "liveview"],
      sensitive?: false,
      type: :string_list,
      writable?: true
    },
    "dynamic_codegen.live_loader_enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "dynamic_codegen.max_bytes" => %{
      default: 262_144,
      max: 5_242_880,
      min: 1024,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "dynamic_codegen.max_files" => %{
      default: 32,
      max: 200,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "dynamic_codegen.max_provider_calls_per_gap" => %{
      default: 8,
      max: 40,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "dynamic_codegen.max_provider_usage_units_per_gap" => %{
      default: 20000,
      sensitive?: false,
      type: :non_negative_integer_or_nil,
      writable?: true
    },
    "dynamic_codegen.max_repair_iterations" => %{
      default: 2,
      max: 8,
      min: 0,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "dynamic_codegen.provider_profile" => %{
      default: nil,
      sensitive?: false,
      type: :string_or_nil,
      writable?: true
    },
    "dynamic_codegen.retention_days" => %{
      default: 30,
      max: 365,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    }
  }
  @defaults %{
    "dynamic_codegen" => %{
      "allowed_action_permissions" => ["read_only"],
      "allowed_facades" => [],
      "allowed_targets" => ["action"],
      "enabled" => false,
      "integration_approval_surfaces" => ["cli", "liveview"],
      "live_loader_enabled" => false,
      "max_bytes" => 262_144,
      "max_files" => 32,
      "max_provider_calls_per_gap" => 8,
      "max_provider_usage_units_per_gap" => 20000,
      "max_repair_iterations" => 2,
      "provider_profile" => nil,
      "retention_days" => 30
    }
  }
  @safe_write_keys [
    "dynamic_codegen.enabled",
    "dynamic_codegen.provider_profile",
    "dynamic_codegen.max_repair_iterations",
    "dynamic_codegen.max_provider_calls_per_gap",
    "dynamic_codegen.max_provider_usage_units_per_gap",
    "dynamic_codegen.max_files",
    "dynamic_codegen.max_bytes",
    "dynamic_codegen.allowed_targets",
    "dynamic_codegen.allowed_action_permissions",
    "dynamic_codegen.allowed_facades",
    "dynamic_codegen.live_loader_enabled",
    "dynamic_codegen.integration_approval_surfaces",
    "dynamic_codegen.retention_days"
  ]
  @safe_write_rows [
    {357, "dynamic_codegen.enabled"},
    {358, "dynamic_codegen.provider_profile"},
    {359, "dynamic_codegen.max_repair_iterations"},
    {360, "dynamic_codegen.max_provider_calls_per_gap"},
    {361, "dynamic_codegen.max_provider_usage_units_per_gap"},
    {362, "dynamic_codegen.max_files"},
    {363, "dynamic_codegen.max_bytes"},
    {364, "dynamic_codegen.allowed_targets"},
    {365, "dynamic_codegen.allowed_action_permissions"},
    {366, "dynamic_codegen.allowed_facades"},
    {367, "dynamic_codegen.live_loader_enabled"},
    {368, "dynamic_codegen.integration_approval_surfaces"},
    {369, "dynamic_codegen.retention_days"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:dynamic_codegen",
      owner: "dynamic_codegen",
      source: :core,
      group: "dynamic_codegen",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Dynamic Codegen"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
