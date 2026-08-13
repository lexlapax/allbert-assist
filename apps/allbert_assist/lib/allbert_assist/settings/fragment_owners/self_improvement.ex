defmodule AllbertAssist.Settings.FragmentOwners.SelfImprovement do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "self_improvement.drafts.max_open" => %{
      default: 50,
      max: 500,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "self_improvement.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "self_improvement.schema_version" => %{
      default: 1,
      max: 1,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: false
    },
    "self_improvement.suggestions.max_open" => %{
      default: 25,
      max: 200,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "self_improvement.suggestions.ttl_days" => %{
      default: 14,
      max: 365,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "self_improvement.trace_index.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "self_improvement.trace_index.max_indexed_entries" => %{
      default: 5000,
      max: 50_000,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "self_improvement.trace_index.min_repetitions" => %{
      default: 3,
      max: 100,
      min: 2,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    }
  }
  @defaults %{
    "self_improvement" => %{
      "drafts" => %{"max_open" => 50},
      "enabled" => false,
      "schema_version" => 1,
      "suggestions" => %{"max_open" => 25, "ttl_days" => 14},
      "trace_index" => %{
        "enabled" => false,
        "max_indexed_entries" => 5000,
        "min_repetitions" => 3
      }
    }
  }
  @safe_write_keys [
    "self_improvement.enabled",
    "self_improvement.trace_index.enabled",
    "self_improvement.trace_index.max_indexed_entries",
    "self_improvement.trace_index.min_repetitions",
    "self_improvement.suggestions.max_open",
    "self_improvement.suggestions.ttl_days",
    "self_improvement.drafts.max_open"
  ]
  @safe_write_rows [
    {303, "self_improvement.enabled"},
    {304, "self_improvement.trace_index.enabled"},
    {305, "self_improvement.trace_index.max_indexed_entries"},
    {306, "self_improvement.trace_index.min_repetitions"},
    {307, "self_improvement.suggestions.max_open"},
    {308, "self_improvement.suggestions.ttl_days"},
    {309, "self_improvement.drafts.max_open"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:self_improvement",
      owner: "self_improvement",
      source: :core,
      group: "self_improvement",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Self Improvement"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
