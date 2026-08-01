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
             :closed_assessment_output,
             :closed_adjudication_output
           ]

    assert length(FanoutPolicy.rule_ids()) ==
             MapSet.size(MapSet.new(FanoutPolicy.rule_ids()))

    assert Enum.map(FanoutPolicy.rule_specs(), & &1.id) == FanoutPolicy.rule_ids()
    refute inspect(FanoutPolicy.rules()) =~ "Juniper"
    refute inspect(FanoutPolicy.rules()) =~ "Friday"
  end

  test "manager policy owns the semantic operator-adjudication criteria" do
    expected = %{
      independent_children_only: [
        :at_least_two_children,
        :independently_useful,
        :concurrent_progress,
        :no_child_result_dependency
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

    assert rule_ids ==
             DirectAnswerPolicy.rule_ids() ++ FanoutPolicy.prompt_rule_ids(:assess)

    assert :closed_assessment_output in rule_ids
    refute :closed_adjudication_output in rule_ids
    assert List.last(prompt.messages).metadata.allbert_prompt.content_class == :operator_input
  end

  test "each manager phase derives only its own closed output rule" do
    assert :closed_assessment_output in FanoutPolicy.prompt_rule_ids(:assess)
    refute :closed_adjudication_output in FanoutPolicy.prompt_rule_ids(:assess)

    assert :closed_adjudication_output in FanoutPolicy.prompt_rule_ids(:adjudicate)
    refute :closed_assessment_output in FanoutPolicy.prompt_rule_ids(:adjudicate)

    assert FanoutPolicy.prompt_rule_ids(:assess) -- FanoutPolicy.prompt_rule_ids(:adjudicate) ==
             [:closed_assessment_output]

    assert FanoutPolicy.prompt_rule_ids(:adjudicate) -- FanoutPolicy.prompt_rule_ids(:assess) ==
             [:closed_adjudication_output]
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
end
