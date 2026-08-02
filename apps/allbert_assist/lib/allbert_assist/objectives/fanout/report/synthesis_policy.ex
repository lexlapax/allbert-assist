defmodule AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy do
  @moduledoc """
  Immutable contract catalog for layout-v2 fan-in synthesis.

  This pure module is the single owner of the contract version, ordered rule
  identifiers, and provider instructions consumed by prompt construction,
  structured-output validation, and durable provenance. It owns no state or
  authority, so neither a Jido agent nor a GenServer is appropriate.
  """

  alias AllbertAssist.Objectives.CanonicalJSON

  @version 1
  @rule_group_catalog_version 1
  @rule_group_catalog_digest_domain "allbert:fanout-synthesis-rule-groups:v1\0"
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

  @rule_groups [
    %{
      "id" => "coverage_relationship",
      "rule_ids" => [
        "complete_child_coverage",
        "parent_join_request_coverage",
        "relationship_support"
      ]
    },
    %{
      "id" => "integrity_authority",
      "rule_ids" => [
        "internal_consistency",
        "uncertainty_marking",
        "no_effect_or_authority_claims",
        "one_paragraph_presentation"
      ]
    }
  ]

  @spec version() :: 1
  def version, do: @version

  @doc "Return the current synthesis rule-group catalog version."
  @spec rule_group_catalog_version() :: 1
  def rule_group_catalog_version, do: @rule_group_catalog_version

  @doc "Return one supported ordered synthesis rule-group catalog."
  @spec rule_groups(term()) ::
          {:ok, [map()]} | {:error, :unsupported_rule_group_catalog_version}
  def rule_groups(@rule_group_catalog_version), do: {:ok, @rule_groups}
  def rule_groups(_version), do: {:error, :unsupported_rule_group_catalog_version}

  @doc "Return the canonical SHA-256 binding for one supported rule-group catalog."
  @spec rule_group_catalog_sha256(term()) ::
          {:ok, String.t()} | {:error, :unsupported_rule_group_catalog_version}
  def rule_group_catalog_sha256(version) do
    with {:ok, groups} <- rule_groups(version) do
      {:ok,
       @rule_group_catalog_digest_domain
       |> Kernel.<>(CanonicalJSON.encode(groups))
       |> sha256()}
    end
  end

  def rules, do: @rules

  @spec rule_ids() :: [String.t()]
  def rule_ids, do: Enum.map(@rules, & &1.id)

  @spec prompt_rules() :: keyword(String.t())
  def prompt_rules, do: Enum.map(@rules, &{&1.prompt_id, &1.instruction})

  @spec prompt_rule_ids() :: [atom()]
  def prompt_rule_ids, do: Enum.map(@rules, & &1.prompt_id)

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
