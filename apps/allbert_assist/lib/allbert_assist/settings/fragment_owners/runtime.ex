defmodule AllbertAssist.Settings.FragmentOwners.Runtime do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "runtime.cost_visibility" => %{
      allowed_values: ["hidden", "summary", "detailed"],
      default: "summary",
      sensitive?: false,
      type: :enum,
      writable?: false
    },
    "runtime.diagnostics_verbosity" => %{
      allowed_values: ["quiet", "normal", "verbose"],
      default: "normal",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "runtime.model_alias" => %{
      default: "local",
      sensitive?: false,
      type: :profile_ref,
      writable?: false
    },
    "runtime.trace_default" => %{
      allowed_values: ["disabled", "enabled", "denied_only"],
      default: "disabled",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "runtime.trace_recent_entries_limit" => %{
      default: 5,
      max: 100,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    }
  }
  @defaults %{
    "runtime" => %{
      "cost_visibility" => "summary",
      "diagnostics_verbosity" => "normal",
      "model_alias" => "local",
      "trace_default" => "disabled",
      "trace_recent_entries_limit" => 5
    }
  }
  @safe_write_keys [
    "runtime.trace_default",
    "runtime.trace_recent_entries_limit",
    "runtime.diagnostics_verbosity"
  ]
  @safe_write_rows [
    {22, "runtime.trace_default"},
    {23, "runtime.trace_recent_entries_limit"},
    {24, "runtime.diagnostics_verbosity"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:runtime",
      owner: "runtime",
      source: :core,
      group: "runtime",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Runtime"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
