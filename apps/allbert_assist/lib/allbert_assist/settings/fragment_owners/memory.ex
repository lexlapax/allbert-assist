defmodule AllbertAssist.Settings.FragmentOwners.Memory do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "memory.auto_promote_sensitive_entries" => %{
      default: false,
      deprecated?: true,
      deprecation_reason:
        "Sensitive Memory promotion always requires the v1.3 proposal/review consent boundary; this stored compatibility value grants no authority.",
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "memory.collection.origin_grants" => %{
      default: [],
      sensitive?: false,
      type: :v13_origin_scopes,
      writable?: true
    },
    "memory.consolidation.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "memory.delete_requires_confirmation" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "memory.index_enabled" => %{default: true, sensitive?: false, type: :boolean, writable?: true},
    "memory.max_entries_per_category" => %{
      default: 500,
      max: 100_000,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "memory.max_index_entries" => %{
      default: 1000,
      max: 100_000,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "memory.promotion_requires_confirmation" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "memory.prune_requires_confirmation" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "memory.retention_policy" => %{
      allowed_values: ["preserve_markdown", "prune_traces_after_30d", "prune_traces_after_90d"],
      default: "preserve_markdown",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "memory.review_cadence" => %{
      allowed_values: ["manual", "daily", "weekly"],
      default: "manual",
      sensitive?: false,
      type: :enum,
      writable?: true
    }
  }
  @defaults %{
    "memory" => %{
      "auto_promote_sensitive_entries" => false,
      "collection" => %{"origin_grants" => []},
      "consolidation" => %{"enabled" => false},
      "delete_requires_confirmation" => true,
      "index_enabled" => true,
      "max_entries_per_category" => 500,
      "max_index_entries" => 1000,
      "promotion_requires_confirmation" => true,
      "prune_requires_confirmation" => true,
      "retention_policy" => "preserve_markdown",
      "review_cadence" => "manual"
    }
  }
  @safe_write_keys [
    "memory.review_cadence",
    "memory.consolidation.enabled",
    "memory.collection.origin_grants",
    "memory.auto_promote_sensitive_entries",
    "memory.retention_policy",
    "memory.delete_requires_confirmation",
    "memory.prune_requires_confirmation",
    "memory.promotion_requires_confirmation",
    "memory.max_entries_per_category",
    "memory.index_enabled",
    "memory.max_index_entries"
  ]
  @safe_write_rows [
    {441, "memory.review_cadence"},
    {442, "memory.consolidation.enabled"},
    {443, "memory.collection.origin_grants"},
    {444, "memory.auto_promote_sensitive_entries"},
    {445, "memory.retention_policy"},
    {446, "memory.delete_requires_confirmation"},
    {447, "memory.prune_requires_confirmation"},
    {448, "memory.promotion_requires_confirmation"},
    {449, "memory.max_entries_per_category"},
    {450, "memory.index_enabled"},
    {451, "memory.max_index_entries"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:memory",
      owner: "memory",
      source: :core,
      group: "memory",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Memory"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
