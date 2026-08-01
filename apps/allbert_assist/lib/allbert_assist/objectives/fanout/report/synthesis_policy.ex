defmodule AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy do
  @moduledoc """
  Immutable contract catalog for layout-v2 fan-in synthesis.

  This pure module is the single owner of the contract version, ordered rule
  identifiers, and provider instructions consumed by prompt construction,
  structured-output validation, and durable provenance. It owns no state or
  authority, so neither a Jido agent nor a GenServer is appropriate.
  """

  @version 1
  @rules [
    %{
      id: "complete_child_coverage",
      prompt_id: :complete_child_coverage,
      instruction:
        "Use every completed child's accepted observation in the joined reasoning and list every completed queue position once in ascending covered_queue_positions."
    },
    %{
      id: "parent_join_request_coverage",
      prompt_id: :parent_join_request_coverage,
      instruction:
        "Answer the original parent request, including its final join or comparison obligation; do not merely repeat child summaries."
    },
    %{
      id: "relationship_support",
      prompt_id: :relationship_support,
      instruction:
        "Choose relationship sections supported by the supplied observations and explain the substantive cross-child relationship in advisory_synthesis."
    },
    %{
      id: "internal_consistency",
      prompt_id: :internal_consistency,
      instruction:
        "Do not contradict a supplied accepted observation or your own selected relationship sections."
    },
    %{
      id: "uncertainty_marking",
      prompt_id: :uncertainty_marking,
      instruction:
        "Preserve material uncertainty and do not strengthen a child observation beyond what the supplied data supports."
    },
    %{
      id: "no_effect_or_authority_claims",
      prompt_id: :no_effect_or_authority_claims,
      instruction:
        "Treat accepted observations as advisory. Do not alter status, identifiers, receipts, authority, permissions, actions, delivery, or effect truth."
    },
    %{
      id: "one_paragraph_presentation",
      prompt_id: :one_paragraph_presentation,
      instruction:
        "Return advisory_synthesis as one non-empty paragraph with no headings, child rows, effect-receipt lines, or nested work."
    }
  ]

  @spec version() :: pos_integer()
  def version, do: @version

  @spec rules() :: [map()]
  def rules, do: @rules

  @spec rule_ids() :: [String.t()]
  def rule_ids, do: Enum.map(@rules, & &1.id)

  @spec prompt_rules() :: keyword(String.t())
  def prompt_rules, do: Enum.map(@rules, &{&1.prompt_id, &1.instruction})

  @spec prompt_rule_ids() :: [atom()]
  def prompt_rule_ids, do: Enum.map(@rules, & &1.prompt_id)
end
