defmodule AllbertAssist.Settings.FragmentOwners.Intent do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "intent.calendar_mcp_server" => %{
      default: "calendar",
      sensitive?: false,
      type: :string_or_empty,
      writable?: true
    },
    "intent.clarify_floor" => %{
      default: 0.3,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.context_window" => %{
      default: 6,
      max: 24,
      min: 0,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "intent.descriptor_autoaccept" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "intent.descriptors_enabled" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "intent.direct_answer_model_enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "intent.direct_answer_model_profile" => %{
      default: "local",
      sensitive?: false,
      type: :profile_ref,
      writable?: true
    },
    "intent.disambiguation_margin" => %{
      default: 0.12,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.eval.block_on_regression" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "intent.eval.min_accuracy" => %{
      default: 0.85,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.eval.min_per_domain_accuracy" => %{
      default: 0.8,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.handoff_margin" => %{
      default: 0.15,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.handoff_threshold" => %{
      default: 0.6,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.max_candidates" => %{
      default: 80,
      max: 500,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "intent.model_assist_enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "intent.model_min_confidence" => %{
      default: 0.72,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.model_profile" => %{
      default: "local",
      sensitive?: false,
      type: :profile_ref,
      writable?: true
    },
    "intent.model_timeout_ms" => %{
      default: 3000,
      sensitive?: false,
      type: :timeout_ms,
      writable?: true
    },
    "intent.multiturn_enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "intent.pending_clarification_ttl_ms" => %{
      default: 120_000,
      max: 3_600_000,
      min: 1000,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "intent.reindex_on_registration_signal" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "intent.router_decisive_confidence" => %{
      default: 0.8,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.router_embedding_profile" => %{
      default: "embedding_local",
      sensitive?: false,
      type: :profile_ref,
      writable?: true
    },
    "intent.router_escalation_profile" => %{
      default: "router_escalation_local",
      sensitive?: false,
      type: :string_or_empty,
      writable?: true
    },
    "intent.router_min_confidence" => %{
      default: 0.6,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.router_model_profile" => %{
      default: "router_local",
      sensitive?: false,
      type: :profile_ref,
      writable?: true
    },
    "intent.router_model_timeout_ms" => %{
      default: 20000,
      max: 60000,
      min: 250,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "intent.router_scoring.prefilter.complete_required_slots_boost" => %{
      default: 0.35,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.router_scoring.prefilter.descriptor_text_match_boost" => %{
      default: 0.35,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.router_scoring.prefilter.descriptor_text_match_cap" => %{
      default: 0.25,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.router_scoring.prefilter.descriptor_text_match_unit_boost" => %{
      default: 0.04,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.router_scoring.prefilter.missing_required_slots_penalty" => %{
      default: 0.25,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.router_scoring.ranker.complete_required_slots_boost" => %{
      default: 0.35,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.router_scoring.ranker.descriptor_text_match_boost" => %{
      default: 0.45,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.router_scoring.ranker.descriptor_text_match_cap" => %{
      default: 0.25,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.router_scoring.ranker.descriptor_text_match_unit_boost" => %{
      default: 0.05,
      max: 1.0,
      min: 0.0,
      sensitive?: false,
      type: :bounded_float,
      writable?: true
    },
    "intent.router_strategy" => %{
      allowed_values: ["deterministic", "two_stage_local"],
      default: "two_stage_local",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "intent.router_top_k" => %{
      default: 5,
      max: 20,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "intent.trace_rejected_candidates" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    }
  }
  @defaults %{
    "intent" => %{
      "calendar_mcp_server" => "calendar",
      "clarify_floor" => 0.3,
      "context_window" => 6,
      "descriptor_autoaccept" => false,
      "descriptors_enabled" => true,
      "direct_answer_model_enabled" => false,
      "direct_answer_model_profile" => "local",
      "disambiguation_margin" => 0.12,
      "eval" => %{
        "block_on_regression" => true,
        "min_accuracy" => 0.85,
        "min_per_domain_accuracy" => 0.8
      },
      "handoff_margin" => 0.15,
      "handoff_threshold" => 0.6,
      "max_candidates" => 80,
      "model_assist_enabled" => false,
      "model_min_confidence" => 0.72,
      "model_profile" => "local",
      "model_timeout_ms" => 3000,
      "multiturn_enabled" => false,
      "pending_clarification_ttl_ms" => 120_000,
      "reindex_on_registration_signal" => true,
      "router_decisive_confidence" => 0.8,
      "router_embedding_profile" => "embedding_local",
      "router_escalation_profile" => "router_escalation_local",
      "router_min_confidence" => 0.6,
      "router_model_profile" => "router_local",
      "router_model_timeout_ms" => 20000,
      "router_scoring" => %{
        "prefilter" => %{
          "complete_required_slots_boost" => 0.35,
          "descriptor_text_match_boost" => 0.35,
          "descriptor_text_match_cap" => 0.25,
          "descriptor_text_match_unit_boost" => 0.04,
          "missing_required_slots_penalty" => 0.25
        },
        "ranker" => %{
          "complete_required_slots_boost" => 0.35,
          "descriptor_text_match_boost" => 0.45,
          "descriptor_text_match_cap" => 0.25,
          "descriptor_text_match_unit_boost" => 0.05
        }
      },
      "router_strategy" => "two_stage_local",
      "router_top_k" => 5,
      "trace_rejected_candidates" => true
    }
  }
  @safe_write_keys [
    "intent.model_assist_enabled",
    "intent.model_profile",
    "intent.model_timeout_ms",
    "intent.model_min_confidence",
    "intent.max_candidates",
    "intent.trace_rejected_candidates",
    "intent.descriptors_enabled",
    "intent.handoff_threshold",
    "intent.handoff_margin",
    "intent.clarify_floor",
    "intent.direct_answer_model_enabled",
    "intent.direct_answer_model_profile",
    "intent.router_strategy",
    "intent.router_embedding_profile",
    "intent.router_model_profile",
    "intent.router_escalation_profile",
    "intent.router_top_k",
    "intent.router_min_confidence",
    "intent.router_decisive_confidence",
    "intent.router_model_timeout_ms",
    "intent.router_scoring.prefilter.complete_required_slots_boost",
    "intent.router_scoring.prefilter.missing_required_slots_penalty",
    "intent.router_scoring.prefilter.descriptor_text_match_boost",
    "intent.router_scoring.prefilter.descriptor_text_match_unit_boost",
    "intent.router_scoring.prefilter.descriptor_text_match_cap",
    "intent.router_scoring.ranker.complete_required_slots_boost",
    "intent.router_scoring.ranker.descriptor_text_match_boost",
    "intent.router_scoring.ranker.descriptor_text_match_unit_boost",
    "intent.router_scoring.ranker.descriptor_text_match_cap",
    "intent.eval.min_accuracy",
    "intent.eval.min_per_domain_accuracy",
    "intent.eval.block_on_regression",
    "intent.reindex_on_registration_signal",
    "intent.calendar_mcp_server",
    "intent.multiturn_enabled",
    "intent.context_window",
    "intent.disambiguation_margin",
    "intent.pending_clarification_ttl_ms",
    "intent.descriptor_autoaccept"
  ]
  @safe_write_rows [
    {25, "intent.model_assist_enabled"},
    {26, "intent.model_profile"},
    {27, "intent.model_timeout_ms"},
    {28, "intent.model_min_confidence"},
    {29, "intent.max_candidates"},
    {30, "intent.trace_rejected_candidates"},
    {31, "intent.descriptors_enabled"},
    {32, "intent.handoff_threshold"},
    {33, "intent.handoff_margin"},
    {34, "intent.clarify_floor"},
    {35, "intent.direct_answer_model_enabled"},
    {36, "intent.direct_answer_model_profile"},
    {37, "intent.router_strategy"},
    {38, "intent.router_embedding_profile"},
    {39, "intent.router_model_profile"},
    {40, "intent.router_escalation_profile"},
    {41, "intent.router_top_k"},
    {42, "intent.router_min_confidence"},
    {43, "intent.router_decisive_confidence"},
    {44, "intent.router_model_timeout_ms"},
    {45, "intent.router_scoring.prefilter.complete_required_slots_boost"},
    {46, "intent.router_scoring.prefilter.missing_required_slots_penalty"},
    {47, "intent.router_scoring.prefilter.descriptor_text_match_boost"},
    {48, "intent.router_scoring.prefilter.descriptor_text_match_unit_boost"},
    {49, "intent.router_scoring.prefilter.descriptor_text_match_cap"},
    {50, "intent.router_scoring.ranker.complete_required_slots_boost"},
    {51, "intent.router_scoring.ranker.descriptor_text_match_boost"},
    {52, "intent.router_scoring.ranker.descriptor_text_match_unit_boost"},
    {53, "intent.router_scoring.ranker.descriptor_text_match_cap"},
    {54, "intent.eval.min_accuracy"},
    {55, "intent.eval.min_per_domain_accuracy"},
    {56, "intent.eval.block_on_regression"},
    {57, "intent.reindex_on_registration_signal"},
    {58, "intent.calendar_mcp_server"},
    {59, "intent.multiturn_enabled"},
    {60, "intent.context_window"},
    {61, "intent.disambiguation_margin"},
    {62, "intent.pending_clarification_ttl_ms"},
    {63, "intent.descriptor_autoaccept"}
  ]

  @agent_defaults %{
    "agents" => %{
      "primary_intent" => %{
        "type" => "code",
        "module" => "AllbertAssist.Agents.IntentAgent",
        "model_profile" => "local",
        "enabled" => true
      }
    }
  }

  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:intent",
      owner: "intent",
      source: :core,
      group: "intent",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Intent"}
    })
  end

  @impl true
  def composition_defaults, do: Map.merge(@defaults, @agent_defaults)

  @impl true
  def dynamic_default_keys, do: ["agents.primary_intent.*"]

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
