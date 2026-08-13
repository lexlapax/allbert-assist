defmodule AllbertAssist.Settings.FragmentOwners.Plan do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "plan.preview.auto_proceed_green_tier" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "plan.preview.confidence_tier_engine" => %{
      allowed_values: ["deterministic_v1"],
      default: "deterministic_v1",
      sensitive?: false,
      type: :enum,
      writable?: false
    },
    "plan.preview.show_confidence_tier" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "plan.preview.show_estimated_cost" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "plan.preview.show_failure_blast_radius" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "plan.run.cancel_grace_ms" => %{
      default: 5000,
      max: 30_000,
      min: 0,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "plan.run.default_concurrency" => %{
      default: 1,
      max: 1,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: false
    },
    "plan.run.plan_start_gate" => %{
      allowed_values: ["required"],
      default: "required",
      sensitive?: false,
      type: :enum,
      writable?: false
    },
    "plan.subagent.delegation_visibility" => %{
      allowed_values: ["expanded_inline"],
      default: "expanded_inline",
      sensitive?: false,
      type: :enum,
      writable?: false
    }
  }
  @defaults %{
    "plan" => %{
      "preview" => %{
        "auto_proceed_green_tier" => false,
        "confidence_tier_engine" => "deterministic_v1",
        "show_confidence_tier" => true,
        "show_estimated_cost" => true,
        "show_failure_blast_radius" => true
      },
      "run" => %{
        "cancel_grace_ms" => 5000,
        "default_concurrency" => 1,
        "plan_start_gate" => "required"
      },
      "subagent" => %{"delegation_visibility" => "expanded_inline"}
    }
  }
  @safe_write_keys [
    "plan.preview.show_estimated_cost",
    "plan.preview.show_failure_blast_radius",
    "plan.preview.show_confidence_tier",
    "plan.preview.auto_proceed_green_tier",
    "plan.run.cancel_grace_ms"
  ]
  @safe_write_rows [
    {256, "plan.preview.show_estimated_cost"},
    {257, "plan.preview.show_failure_blast_radius"},
    {258, "plan.preview.show_confidence_tier"},
    {259, "plan.preview.auto_proceed_green_tier"},
    {260, "plan.run.cancel_grace_ms"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:plan",
      owner: "plan",
      source: :core,
      group: "plan",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Plan"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
