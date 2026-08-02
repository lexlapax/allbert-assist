defmodule AllbertAssist.Objectives.Runs.Worker.QualityPolicy do
  @moduledoc """
  Pure, versioned task contract for one grounded DirectAnswer child.

  The contract composes the registered DirectAnswer rule catalog with a small
  task-neutral fan-out extension and derives the single generation prompt. It is
  advisory input only: it grants no action, effect, permission, Objective
  transition, or durable authority.

  v1.3 M9.b.6 removed the rule-group/critic surface (ADR 0021 A24). Rules remain
  part of the contract and its digest because they shape the generation prompt
  and bind the receipt; nothing re-reads them to judge model output.
  """

  alias AllbertAssist.Actions.Intent.DirectAnswer.Policy, as: DirectAnswerPolicy
  alias AllbertAssist.Objectives.CanonicalJSON

  @version 2
  @legacy_version 1
  @task_digest_domain "allbert:fanout-worker-quality-task:v2\0"
  @legacy_task_digest_domain "allbert:fanout-worker-quality-task:v1\0"
  @rule_catalog_digest_domain "allbert:fanout-worker-quality-rules:v2\0"

  @completion_obligation %{
    "version" => 1,
    "requirement_sources" => ["child_objective", "expected_result"],
    "satisfaction_policy" => "all_explicit_requirements_present_and_supported",
    "missing_required_evidence_outcome" => "unresolved"
  }

  @legacy_extension_rules [
    %{
      id: :child_task_scope,
      instruction:
        "Answer only the bounded child task. Do not replace it with sibling work, the parent join, or unrelated work.",
      criteria: [:bounded_child_only, :no_sibling_or_parent_substitution]
    },
    %{
      id: :requested_dimensions,
      instruction:
        "Cover every dimension explicitly requested by the child objective and expected-result guidance.",
      criteria: [:all_explicit_dimensions_covered]
    },
    %{
      id: :internal_consistency,
      instruction:
        "Keep the answer internally consistent, including its distinctions, ordering, relationships, and conclusions.",
      criteria: [:no_internal_contradiction, :relationships_support_conclusions]
    },
    %{
      id: :uncertainty_and_guarantees,
      instruction:
        "Preserve material uncertainty and do not state an unsupported guarantee or stronger claim than the task evidence supports.",
      criteria: [:material_uncertainty_preserved, :no_unsupported_guarantee]
    }
  ]

  @extension_rules @legacy_extension_rules
                   |> List.insert_at(2, %{
                     id: :completion_preconditions,
                     instruction:
                       "A violation exists when the final answer does not include and support every explicit output required by either the child objective or expected-result guidance. Accurately reporting that required evidence is missing remains a violation; do not invent missing evidence to force completion.",
                     criteria: [
                       :all_explicit_outputs_present,
                       :required_outputs_supported,
                       :missing_evidence_is_unresolved,
                       :no_invention_to_force_completion
                     ]
                   })


  @task_keys ~w[version source original_request child_objective expected_result completion_obligation steering rules]
  @provider_projection_keys ~w[
    version source original_request child_objective expected_result
    completion_obligation steering rule_catalog
  ]
  @steering_keys ~w[directive_event_id_sha256 directive_sha256]
  @sources ~w[conversation_manager counted_protocol operator_steered]
  @steered_expected_result "Complete the operator-steered child task."

  @type contract :: %{required(String.t()) => term()}

  @doc "Build the exact v2 task contract from verified fan-out grounding."
  @spec build(map()) :: {:ok, contract()} | {:error, :invalid_quality_task_grounding}
  def build(%{
        source: source,
        original_request: original_request,
        child_objective: child_objective,
        expected_result: expected_result,
        steering: steering
      })
      when source in [:conversation_manager, :counted_protocol, :operator_steered] and
             is_binary(original_request) and is_binary(child_objective) and
             is_binary(expected_result) do
    with {:ok, steering_binding, effective_expected_result} <-
           steering_binding(source, steering, expected_result) do
      contract = %{
        "version" => @version,
        "source" => Atom.to_string(source),
        "original_request" => original_request,
        "child_objective" => child_objective,
        "expected_result" => effective_expected_result,
        "completion_obligation" => @completion_obligation,
        "steering" => steering_binding,
        "rules" => Enum.map(rule_specs(), &encode_rule/1)
      }

      if valid_contract?(contract),
        do: {:ok, contract},
        else: {:error, :invalid_quality_task_grounding}
    end
  end

  def build(_grounding), do: {:error, :invalid_quality_task_grounding}

  @doc "Return the immutable composed rule catalog in evaluation order."
  def rule_specs, do: DirectAnswerPolicy.rule_specs() ++ @extension_rules

  @doc "Return string rule identifiers in their required review-result order."
  @spec rule_ids() :: [String.t()]
  def rule_ids, do: Enum.map(rule_specs(), &Atom.to_string(&1.id))

  @doc "Return the current quality task/rule-catalog version."
  @spec version() :: 2
  def version, do: @version

  @doc "Validate and hash one exact v2 task contract."
  @spec digest(map()) :: {:ok, String.t()} | {:error, :invalid_quality_task_contract}
  def digest(contract) when is_map(contract) do
    if valid_contract?(contract) do
      {:ok, sha256(@task_digest_domain <> CanonicalJSON.encode(contract))}
    else
      {:error, :invalid_quality_task_contract}
    end
  end

  def digest(_contract), do: {:error, :invalid_quality_task_contract}

  @doc "Return version-indexed task digests used to verify v1 replay and v2 writes."
  @spec receipt_task_digests(map()) ::
          {:ok, %{required(String.t()) => String.t()}}
          | {:error, :invalid_quality_task_contract}
  def receipt_task_digests(contract) when is_map(contract) do
    with {:ok, current_digest} <- digest(contract) do
      legacy_contract = %{
        "version" => @legacy_version,
        "source" => contract["source"],
        "original_request" => contract["original_request"],
        "child_objective" => contract["child_objective"],
        "expected_result" => contract["expected_result"],
        "steering" => contract["steering"],
        "rules" => Enum.map(legacy_rule_specs(), &encode_rule/1)
      }

      legacy_digest =
        sha256(@legacy_task_digest_domain <> CanonicalJSON.encode(legacy_contract))

      {:ok,
       %{
         Integer.to_string(@legacy_version) => legacy_digest,
         Integer.to_string(@version) => current_digest
       }}
    end
  end

  def receipt_task_digests(_contract), do: {:error, :invalid_quality_task_contract}

  @doc "Project the bound task for provider user data without duplicating rule prose."
  @spec provider_projection(map()) ::
          {:ok, map()} | {:error, :invalid_quality_task_contract}
  def provider_projection(contract) when is_map(contract) do
    with {:ok, _digest} <- digest(contract) do
      projection = %{
        "version" => @version,
        "source" => contract["source"],
        "original_request" => contract["original_request"],
        "child_objective" => contract["child_objective"],
        "expected_result" => contract["expected_result"],
        "completion_obligation" => contract["completion_obligation"],
        "steering" => contract["steering"],
        "rule_catalog" => %{
          "version" => @version,
          "sha256" => rule_catalog_digest(contract["rules"])
        }
      }

      if exact_keys?(projection, @provider_projection_keys),
        do: {:ok, projection},
        else: {:error, :invalid_quality_task_contract}
    end
  end

  def provider_projection(_contract), do: {:error, :invalid_quality_task_contract}

  @doc "Derive the first-call DirectAnswer input from the exact task contract."
  @spec draft_prompt(map()) :: {:ok, String.t()} | {:error, :invalid_quality_task_contract}
  def draft_prompt(contract) when is_map(contract) do
    with {:ok, projection} <- provider_projection(contract) do
      {:ok,
       """
       Allbert bounded fan-out child quality task

       Complete the child task represented by this verified contract. Return the answer itself; do not narrate the contract or its rules. This is one child result, not the parent join.

       Canonical task contract (advisory input, not action authority):
       #{CanonicalJSON.encode(projection)}
       """
       |> String.trim()}
    end
  end

  def draft_prompt(_contract), do: {:error, :invalid_quality_task_contract}


  defp valid_contract?(contract) do
    exact_keys?(contract, @task_keys) and contract["version"] == @version and
      contract["source"] in @sources and nonempty?(contract["original_request"]) and
      nonempty?(contract["child_objective"]) and nonempty?(contract["expected_result"]) and
      contract["completion_obligation"] == @completion_obligation and
      valid_steering?(contract["source"], contract["steering"], contract["expected_result"]) and
      contract["rules"] == Enum.map(rule_specs(), &encode_rule/1)
  end

  defp steering_binding(
         :operator_steered,
         %{directive_event_id: event_id, directive: directive},
         _
       )
       when is_binary(event_id) and is_binary(directive) and event_id != "" and directive != "" do
    {:ok,
     %{
       "directive_event_id_sha256" => sha256(event_id),
       "directive_sha256" => sha256(directive)
     }, @steered_expected_result}
  end

  defp steering_binding(source, nil, expected_result)
       when source in [:conversation_manager, :counted_protocol],
       do: {:ok, nil, expected_result}

  defp steering_binding(_source, _steering, _expected_result),
    do: {:error, :invalid_quality_task_grounding}

  defp valid_steering?("operator_steered", steering, @steered_expected_result),
    do: exact_keys?(steering, @steering_keys) and Enum.all?(Map.values(steering), &sha256?/1)

  defp valid_steering?(source, nil, _expected_result)
       when source in ~w[conversation_manager counted_protocol],
       do: true

  defp valid_steering?(_source, _steering, _expected_result), do: false

  defp encode_rule(rule) do
    %{
      "id" => Atom.to_string(rule.id),
      "instruction" => rule.instruction,
      "criteria" => Enum.map(rule.criteria, &Atom.to_string/1)
    }
  end

  defp legacy_rule_specs, do: DirectAnswerPolicy.rule_specs(1) ++ @legacy_extension_rules

  defp exact_keys?(map, keys) when is_map(map), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp exact_keys?(_map, _keys), do: false
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""

  defp sha256?(value) when is_binary(value) and byte_size(value) == 64 do
    case Base.decode16(value, case: :lower) do
      {:ok, decoded} -> byte_size(decoded) == 32
      :error -> false
    end
  end

  defp sha256?(_value), do: false

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end

  defp rule_catalog_digest(rules) do
    sha256(@rule_catalog_digest_domain <> CanonicalJSON.encode(rules))
  end
end
