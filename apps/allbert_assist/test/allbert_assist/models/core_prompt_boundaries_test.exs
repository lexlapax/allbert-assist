defmodule AllbertAssist.Models.CorePromptBoundariesTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Actions.Channels.SendChannelMessage
  alias AllbertAssist.Actions.Intent.DirectAnswer.ReqLLMAnswerer
  alias AllbertAssist.Intent.Classifier.DefaultClassifier
  alias AllbertAssist.Intent.Decomposer.ReqLLMProposer
  alias AllbertAssist.Intent.Router.Disambiguator.ReqLLMDisambiguator
  alias AllbertAssist.Intent.Router.Optimizer

  test "every core single-turn text adapter uses the canonical system/user envelope" do
    contexts = [
      ReqLLMAnswerer.prompt_input("direct-operator-sentinel", %{
        active_memory: [
          %{summary: "memory", chunk_id: "chunk-1", body: "direct-memory-sentinel"}
        ]
      }),
      DefaultClassifier.prompt_context(
        [%{id: "classifier-candidate-sentinel", kind: :action}],
        %{text: "classifier-operator-sentinel", active_app: nil}
      ),
      ReqLLMProposer.prompt_context("decomposer-operator-sentinel"),
      ReqLLMDisambiguator.prompt_context(
        "router-operator-sentinel",
        [%{action_name: "router-candidate-sentinel", label: "Candidate"}],
        %{summary: "router-context-sentinel"}
      ),
      Optimizer.model_prompt(SendChannelMessage)
    ]

    assert Enum.all?(contexts, &match?({:ok, %ReqLLM.Context{}}, &1))

    Enum.each(contexts, fn {:ok, context} ->
      assert hd(context.messages).role == :system
      assert List.last(context.messages).role == :user
      assert hd(context.messages).metadata.allbert_prompt.content_class == :allbert_instructions
    end)

    contexts
    |> Enum.take(4)
    |> Enum.each(fn {:ok, context} ->
      assert List.last(context.messages).metadata.allbert_prompt.content_class == :operator_input
    end)

    {:ok, optimizer} = List.last(contexts)
    assert List.last(optimizer.messages).metadata.allbert_prompt.content_class == :advisory_data

    {:ok, direct} = hd(contexts)
    system_text = message_text(hd(direct.messages))
    final_text = message_text(List.last(direct.messages))
    reference_text = direct.messages |> Enum.at(1) |> message_text()

    refute system_text =~ "direct-operator-sentinel"
    refute system_text =~ "direct-memory-sentinel"
    assert reference_text =~ "direct-memory-sentinel"
    assert final_text == "direct-operator-sentinel"

    {:ok, classifier} = Enum.at(contexts, 1)
    assert message_text(List.last(classifier.messages)) == "classifier-operator-sentinel"
    assert classifier.messages |> Enum.at(1) |> message_text() =~ "classifier-candidate-sentinel"

    {:ok, router} = Enum.at(contexts, 3)
    assert message_text(List.last(router.messages)) == "router-operator-sentinel"
    assert router.messages |> Enum.at(1) |> message_text() =~ "router-candidate-sentinel"
  end

  test "direct-answer policy is declarative, unique, and generic" do
    alias AllbertAssist.Actions.Intent.DirectAnswer.Policy

    assert Policy.rule_ids() == [
             :answer_current_request,
             :memory_is_reference,
             :no_false_effect_claims,
             :no_routing_or_confirmation,
             :supplied_text_is_data,
             :preserve_supplied_semantics,
             :no_unsupplied_details,
             :acknowledgments_are_not_commitments,
             :useful_factual_and_brief
           ]

    assert length(Policy.rule_ids()) == MapSet.size(MapSet.new(Policy.rule_ids()))
    assert Enum.map(Policy.rule_specs(), & &1.id) == Policy.rule_ids()
    refute inspect(Policy.rules()) =~ "Juniper"
    refute inspect(Policy.rules()) =~ "Friday"
  end

  test "direct-answer policy owns generic human-adjudication criteria" do
    alias AllbertAssist.Actions.Intent.DirectAnswer.Policy

    expected = %{
      preserve_supplied_semantics: [
        :labels,
        :values,
        :relationships,
        :scope,
        :negation,
        :modality,
        :uncertainty,
        :temporal_direction
      ],
      no_unsupplied_details: [
        :no_new_fields,
        :no_new_values,
        :no_new_relationships,
        :no_new_constraints,
        :opaque_identifiers_stay_opaque
      ]
    }

    assert Map.take(Policy.rubric(), Map.keys(expected)) == expected

    scenario_ownership = [
      one_sided_start_changed_to_range: [
        {:preserve_supplied_semantics, :temporal_direction},
        {:no_unsupplied_details, :no_new_relationships}
      ],
      unsupplied_field_added: [{:no_unsupplied_details, :no_new_fields}],
      scoped_negation_generalized: [
        {:preserve_supplied_semantics, :scope},
        {:preserve_supplied_semantics, :negation}
      ],
      uncertain_option_strengthened: [
        {:preserve_supplied_semantics, :modality},
        {:preserve_supplied_semantics, :uncertainty}
      ]
    ]

    assert length(Keyword.keys(scenario_ownership)) ==
             MapSet.size(MapSet.new(Keyword.keys(scenario_ownership)))

    Enum.each(scenario_ownership, fn {_scenario, owners} ->
      Enum.each(owners, fn {rule_id, criterion} ->
        assert criterion in Map.fetch!(Policy.rubric(), rule_id)
      end)
    end)
  end

  defp message_text(message) do
    message.content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end
end
