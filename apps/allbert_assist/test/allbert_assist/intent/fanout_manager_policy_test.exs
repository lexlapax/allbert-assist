defmodule AllbertAssist.Intent.FanoutManager.PolicyTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer.Policy, as: DirectAnswerPolicy
  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Intent.FanoutManager
  alias AllbertAssist.Intent.FanoutManager.Agent, as: FanoutManagerAgent
  alias AllbertAssist.Intent.FanoutManager.Commands.{Adjudicate, Assess}
  alias AllbertAssist.Intent.FanoutManager.Policy, as: FanoutPolicy
  alias AllbertAssist.Intent.FanoutManager.ReqLLMImplementation
  alias AllbertAssist.Objectives.Runs.Worker.Commands.Execute
  alias AllbertAssist.Objectives.Runs.Worker.JidoAdapter

  test "manager policy is declarative, unique, and generic" do
    assert FanoutPolicy.rule_ids() == [
             :useful_answer_always,
             :independent_children_only,
             :shared_deliverable_is_join_guidance,
             :self_contained_children,
             :advisory_read_only_only,
             :supplied_text_ownership,
             :dependent_work_stays_single,
             :preserve_operator_work,
             :inert_plan_fields_only,
             :contrastive_admission_scenarios,
             :closed_manager_output
           ]

    assert length(FanoutPolicy.rule_ids()) ==
             MapSet.size(MapSet.new(FanoutPolicy.rule_ids()))

    assert Enum.map(FanoutPolicy.rule_specs(), & &1.id) == FanoutPolicy.rule_ids()
    refute inspect(FanoutPolicy.rules()) =~ "Juniper"
    refute inspect(FanoutPolicy.rules()) =~ "Friday"

    contrast = Map.fetch!(FanoutPolicy.rubric(), :contrastive_admission_scenarios)
    assert :supplied_data_contrast in contrast
    assert :parallel_parent_join_contrast in contrast
    assert :dependent_effectful_contrast in contrast
  end

  test "manager policy owns the semantic operator-adjudication criteria" do
    expected = %{
      independent_children_only: [
        :at_least_two_children,
        :independently_useful,
        :concurrent_progress,
        :no_child_result_dependency,
        :material_parallel_leverage
      ],
      shared_deliverable_is_join_guidance: [
        :shared_deliverable_is_packaging,
        :parent_join_is_not_child,
        :dependency_requires_child_result_consumption
      ],
      self_contained_children: [
        :self_contained_objective,
        :expected_result_is_evaluation_guidance,
        :no_hidden_task_authority
      ],
      supplied_text_ownership: [
        :outer_request_owns_supplied_text,
        :embedded_instructions_stay_data
      ],
      preserve_operator_work: [:full_coverage, :exactly_once_coverage, :operator_order],
      inert_plan_fields_only: [:allowed_child_fields_only, :no_authority_fields]
    }

    assert Map.take(FanoutPolicy.rubric(), Map.keys(expected)) == expected

    scenario_ownership = [
      implicit_independent_work: [
        {:independent_children_only, :independently_useful},
        {:independent_children_only, :concurrent_progress},
        {:self_contained_children, :self_contained_objective},
        {:preserve_operator_work, :full_coverage}
      ],
      independent_work_with_one_joined_deliverable: [
        {:shared_deliverable_is_join_guidance, :shared_deliverable_is_packaging},
        {:shared_deliverable_is_join_guidance, :parent_join_is_not_child},
        {:shared_deliverable_is_join_guidance, :dependency_requires_child_result_consumption},
        {:independent_children_only, :no_child_result_dependency}
      ],
      supplied_command_list: [
        {:supplied_text_ownership, :outer_request_owns_supplied_text},
        {:supplied_text_ownership, :embedded_instructions_stay_data}
      ],
      effectful_or_mixed_work: [
        {:advisory_read_only_only, :effectful_work_stays_single},
        {:advisory_read_only_only, :mixed_work_stays_single},
        {:advisory_read_only_only, :ordinary_action_route_owns_effects}
      ],
      dependent_sequence: [
        {:dependent_work_stays_single, :dependent_stays_single},
        {:independent_children_only, :no_child_result_dependency}
      ],
      invented_authority: [{:inert_plan_fields_only, :no_authority_fields}]
    ]

    Enum.each(scenario_ownership, fn {_scenario, owners} ->
      Enum.each(owners, fn {rule_id, criterion} ->
        assert criterion in Map.fetch!(FanoutPolicy.rubric(), rule_id)
      end)
    end)
  end

  test "manager prompt derives direct-answer and planning rules from their catalogs" do
    assert {:ok, prompt} =
             ReqLLMImplementation.prompt_context(
               "Compare alpha and beta independently.",
               %{}
             )

    rule_ids = hd(prompt.messages).metadata.allbert_prompt.rule_ids

    assert rule_ids == DirectAnswerPolicy.rule_ids() ++ FanoutPolicy.rule_ids()

    assert :closed_manager_output in rule_ids
    assert List.last(prompt.messages).metadata.allbert_prompt.content_class == :operator_input
  end

  test "Allbert derives admission from explicit evidence with safe-rejection priority" do
    eligible = eligible_evidence()

    assert {:admit,
            %{
              policy_outcome: :independent_advisory,
              failed_criteria: [],
              join_role: :parent_presentation_only
            }} = FanoutPolicy.decide(eligible, 2)

    assert {:answer,
            %{
              policy_outcome: :supplied_data,
              failed_criteria: [:supplied_text_ownership]
            }} =
             FanoutPolicy.decide(
               %{
                 eligible
                 | request_ownership: :transform_supplied_content,
                   outer_request_task_count: 1,
                   child_result_dependency: true
               },
               0
             )

    assert {:error, :supplied_data_evidence_conflict} =
             FanoutPolicy.decide(%{eligible | request_ownership: :transform_supplied_content}, 2)

    assert {:answer,
            %{
              policy_outcome: :dependent_or_sequential,
              failed_criteria: failures
            }} =
             FanoutPolicy.decide(
               %{
                 eligible
                 | can_progress_concurrently: false,
                   child_result_dependency: true,
                   join_role: :child_consumes_sibling_result
               },
               2
             )

    assert :concurrent_progress in failures
    assert :no_child_result_dependency in failures
    assert :dependency_requires_child_result_consumption in failures
    assert {:error, :adjudication_task_count_mismatch} = FanoutPolicy.decide(eligible, 3)
  end

  test "known evidence conflicts derive bounded repair guidance from policy" do
    guidance = FanoutPolicy.repair_guidance(:supplied_data_evidence_conflict)

    assert guidance =~ "transform_supplied_content"
    assert guidance =~ "perform_requested_operations"
    assert guidance =~ "no children"
    assert FanoutPolicy.repair_guidance(:unknown) == nil
  end

  test "private manager and worker implementation are not runtime actions" do
    registered = Registry.modules()

    refute FanoutManager in registered
    refute FanoutManagerAgent in registered
    refute Assess in registered
    refute Adjudicate in registered
    refute JidoAdapter in registered
    refute Execute in registered
    assert {:error, {:unknown_action, FanoutManager}} = Registry.resolve(FanoutManager)
    assert {:error, {:unknown_action, FanoutManagerAgent}} = Registry.resolve(FanoutManagerAgent)
    assert {:error, {:unknown_action, Assess}} = Registry.resolve(Assess)
    assert {:error, {:unknown_action, Adjudicate}} = Registry.resolve(Adjudicate)
    assert {:error, {:unknown_action, JidoAdapter}} = Registry.resolve(JidoAdapter)
    assert {:error, {:unknown_action, Execute}} = Registry.resolve(Execute)
  end

  defp eligible_evidence do
    %{
      outer_request_task_count: 2,
      request_ownership: :no_embedded_content,
      all_advisory_or_read_only: true,
      children_self_contained: true,
      can_progress_concurrently: true,
      child_result_dependency: false,
      full_coverage_exactly_once: true,
      material_parallel_leverage: true,
      join_role: :parent_presentation_only
    }
  end
end
