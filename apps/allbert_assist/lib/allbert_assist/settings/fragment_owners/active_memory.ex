defmodule AllbertAssist.Settings.FragmentOwners.ActiveMemory do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "active_memory.chunk_max_bytes" => %{
      default: 2048,
      max: 8192,
      min: 128,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "active_memory.enabled" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "active_memory.excluded_sample_limit" => %{
      default: 5,
      max: 100,
      min: 0,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "active_memory.internal_candidate_limit" => %{
      default: 1000,
      max: 50_000,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "active_memory.score_weights.identity_inclusion" => %{
      default: 1.5,
      max: 10.0,
      min: 1.0e-6,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "active_memory.score_weights.recency_half_life_days" => %{
      default: 30,
      max: 3650,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "active_memory.score_weights.thread_affinity.general" => %{
      default: 0.3,
      max: 10.0,
      min: 1.0e-6,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "active_memory.score_weights.thread_affinity.same_app" => %{
      default: 0.6,
      max: 10.0,
      min: 1.0e-6,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "active_memory.score_weights.thread_affinity.same_thread" => %{
      default: 1.0,
      max: 10.0,
      min: 1.0e-6,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "active_memory.top_k" => %{
      default: 5,
      max: 20,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    }
  }
  @defaults %{
    "active_memory" => %{
      "chunk_max_bytes" => 2048,
      "enabled" => true,
      "excluded_sample_limit" => 5,
      "internal_candidate_limit" => 1000,
      "score_weights" => %{
        "identity_inclusion" => 1.5,
        "recency_half_life_days" => 30,
        "thread_affinity" => %{"general" => 0.3, "same_app" => 0.6, "same_thread" => 1.0}
      },
      "top_k" => 5
    }
  }
  @safe_write_keys [
    "active_memory.enabled",
    "active_memory.top_k",
    "active_memory.chunk_max_bytes",
    "active_memory.internal_candidate_limit",
    "active_memory.excluded_sample_limit",
    "active_memory.score_weights.recency_half_life_days",
    "active_memory.score_weights.thread_affinity.same_thread",
    "active_memory.score_weights.thread_affinity.same_app",
    "active_memory.score_weights.thread_affinity.general",
    "active_memory.score_weights.identity_inclusion"
  ]
  @safe_write_rows [
    {101, "active_memory.enabled"},
    {102, "active_memory.top_k"},
    {103, "active_memory.chunk_max_bytes"},
    {104, "active_memory.internal_candidate_limit"},
    {105, "active_memory.excluded_sample_limit"},
    {106, "active_memory.score_weights.recency_half_life_days"},
    {107, "active_memory.score_weights.thread_affinity.same_thread"},
    {108, "active_memory.score_weights.thread_affinity.same_app"},
    {109, "active_memory.score_weights.thread_affinity.general"},
    {110, "active_memory.score_weights.identity_inclusion"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:active_memory",
      owner: "active_memory",
      source: :core,
      group: "active_memory",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Active Memory"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
