defmodule AllbertAssist.Settings.FragmentOwners.Objectives do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "objectives.enabled" => %{default: true, sensitive?: false, type: :boolean, writable?: true},
    "objectives.fanout.confirm_before_start" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "objectives.fanout.enabled" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "objectives.fanout.max_children_per_fanout" => %{
      default: 8,
      max: 16,
      min: 2,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "objectives.fanout.max_concurrent_runs_global" => %{
      default: 6,
      max: 32,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "objectives.fanout.max_concurrent_runs_per_fanout" => %{
      default: 3,
      max: 8,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "objectives.fanout.max_elapsed_ms_per_plan" => %{
      default: 300_000,
      max: 3_600_000,
      min: 1000,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "objectives.fanout.max_model_calls_per_plan" => %{
      default: 64,
      max: 256,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "objectives.fanout.max_output_tokens_per_plan" => %{
      default: 32768,
      max: 1_000_000,
      min: 1024,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "objectives.fanout.max_worker_attempts_per_child" => %{
      default: 2,
      max: 4,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "objectives.fanout.rollout_mode" => %{
      allowed_values: ["explicit", "shadow", "automatic"],
      default: "automatic",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "objectives.max_loop_count" => %{
      default: 5,
      max: 32,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "objectives.max_steps_per_turn" => %{
      default: 3,
      max: 16,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "objectives.trace_detail" => %{
      allowed_values: ["operator", "debug"],
      default: "operator",
      sensitive?: false,
      type: :enum,
      writable?: true
    }
  }
  @defaults %{
    "objectives" => %{
      "enabled" => true,
      "fanout" => %{
        "confirm_before_start" => false,
        "enabled" => true,
        "max_children_per_fanout" => 8,
        "max_concurrent_runs_global" => 6,
        "max_concurrent_runs_per_fanout" => 3,
        "max_elapsed_ms_per_plan" => 300_000,
        "max_model_calls_per_plan" => 64,
        "max_output_tokens_per_plan" => 32768,
        "max_worker_attempts_per_child" => 2,
        "rollout_mode" => "automatic"
      },
      "max_loop_count" => 5,
      "max_steps_per_turn" => 3,
      "trace_detail" => "operator"
    }
  }
  @safe_write_keys [
    "objectives.enabled",
    "objectives.max_steps_per_turn",
    "objectives.max_loop_count",
    "objectives.trace_detail",
    "objectives.fanout.enabled",
    "objectives.fanout.rollout_mode",
    "objectives.fanout.max_concurrent_runs_per_fanout",
    "objectives.fanout.max_concurrent_runs_global",
    "objectives.fanout.max_children_per_fanout",
    "objectives.fanout.max_model_calls_per_plan",
    "objectives.fanout.max_output_tokens_per_plan",
    "objectives.fanout.max_elapsed_ms_per_plan",
    "objectives.fanout.max_worker_attempts_per_child",
    "objectives.fanout.confirm_before_start"
  ]
  @safe_write_rows [
    {6, "objectives.enabled"},
    {7, "objectives.max_steps_per_turn"},
    {8, "objectives.max_loop_count"},
    {9, "objectives.trace_detail"},
    {10, "objectives.fanout.enabled"},
    {11, "objectives.fanout.rollout_mode"},
    {12, "objectives.fanout.max_concurrent_runs_per_fanout"},
    {13, "objectives.fanout.max_concurrent_runs_global"},
    {14, "objectives.fanout.max_children_per_fanout"},
    {15, "objectives.fanout.max_model_calls_per_plan"},
    {16, "objectives.fanout.max_output_tokens_per_plan"},
    {17, "objectives.fanout.max_elapsed_ms_per_plan"},
    {18, "objectives.fanout.max_worker_attempts_per_child"},
    {19, "objectives.fanout.confirm_before_start"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:objectives",
      owner: "objectives",
      source: :core,
      group: "objectives",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Objectives"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
