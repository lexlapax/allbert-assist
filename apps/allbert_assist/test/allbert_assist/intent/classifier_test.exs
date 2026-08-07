defmodule AllbertAssist.Intent.ClassifierTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Agents.IntentAgent
  alias AllbertAssist.Intent.Classifier
  alias AllbertAssist.Intent.Classifier.FakeClassifier
  alias AllbertAssist.Intent.Engine
  alias AllbertAssist.Intent.EvalFixtures
  alias AllbertAssist.Intent.Router
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @quoted_preference_prompt "What day and time does this sentence say I prefer for Project Juniper status summaries? I prefer Friday at 09:00, valid starting 2026-06-01. The validation marker is juniper-v13-primary. Answer in one sentence."
  @acknowledge_preference_prompt "In one sentence, acknowledge this stated preference: For Project Juniper validation, I prefer status summaries on Friday at 09:00, valid starting 2026-06-01. The validation marker is juniper-v13-primary."

  defmodule RaisingClassifier do
    @behaviour Classifier.Behaviour

    @impl true
    def classify(_candidate_summary, _context), do: raise("classifier should not be called")
  end

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_classifier_config = Application.get_env(:allbert_assist, Classifier)

    original_router_strategy =
      Application.get_env(:allbert_assist, :intent_router_strategy_override)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-classifier-test-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)
    AllbertAssist.StockSageRegistryCase.setup()

    on_exit(fn ->
      restore_home(original_home)
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Classifier, original_classifier_config)
      restore_env(:intent_router_strategy_override, original_router_strategy)
      File.rm_rf!(home)
    end)

    :ok
  end

  test "classifier is disabled by default and does not call configured module" do
    Application.put_env(:allbert_assist, Classifier, classifier: RaisingClassifier)

    candidates = Engine.collect_candidates(EvalFixtures.request())

    assert {:error, %{status: :disabled}} =
             Classifier.classify(candidates, EvalFixtures.request())
  end

  test "two-stage routing skips the legacy classifier and rejects unsupported memory proposals" do
    Application.put_env(:allbert_assist, Classifier, classifier: RaisingClassifier)
    Application.put_env(:allbert_assist, :intent_router_strategy_override, :two_stage_local)

    assert Router.strategy() == :two_stage_local

    assert {:ok, _setting} =
             Settings.put(
               "intent.model_assist_enabled",
               true,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, decision} =
             Engine.decide(EvalFixtures.request(text: @quoted_preference_prompt))

    refute Map.has_key?(decision.trace_metadata, :classifier)
    assert decision.intent == :direct_answer
    assert decision.selected_action == "direct_answer"
  end

  test "an explicit model-off decision never invokes the enabled classifier" do
    Application.put_env(:allbert_assist, Classifier, classifier: RaisingClassifier)
    Application.put_env(:allbert_assist, :intent_router_strategy_override, :deterministic)

    assert {:ok, _setting} =
             Settings.put(
               "intent.model_assist_enabled",
               true,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, decision} =
             Engine.decide(EvalFixtures.request(text: "Remember Project Juniper"),
               model_assist: false
             )

    refute Map.has_key?(decision.trace_metadata, :classifier)
    assert decision.selected_action == "append_memory"
  end

  test "Engine rejects unsupported legacy classifier action proposals" do
    Application.put_env(:allbert_assist, :intent_router_strategy_override, :deterministic)
    enable_fake_classifier!()

    FakeClassifier.put_result(
      {:ok,
       %{
         selected_kind: :action,
         selected_id: "append_memory",
         confidence: 0.99,
         reason: "Quoted preference looked like a write request."
       }}
    )

    for prompt <- [@quoted_preference_prompt, @acknowledge_preference_prompt] do
      assert {:ok, decision} = Engine.decide(EvalFixtures.request(text: prompt))
      assert decision.intent == :direct_answer
      assert decision.selected_action == "direct_answer"
      assert decision.trace_metadata.classifier.status == :used
    end
  end

  test "IntentAgent rejects an unsupported legacy classifier memory proposal" do
    Application.put_env(:allbert_assist, :intent_router_strategy_override, :deterministic)
    enable_fake_classifier!()

    FakeClassifier.put_result(
      {:ok,
       %{
         selected_kind: :action,
         selected_id: "append_memory",
         confidence: 0.99,
         reason: "Supplied preference looked like a write request."
       }}
    )

    assert {:ok, response} =
             IntentAgent.respond(%{
               text: @quoted_preference_prompt,
               user_id: "classifier-boundary-user",
               thread_id: "classifier-boundary-thread"
             })

    assert response.status == :completed
    assert response.decision.selected_action == "direct_answer"
    assert [%{name: "direct_answer"}] = response.actions
  end

  test "fake classifier proposal can select a valid registered surface" do
    enable_fake_classifier!()

    FakeClassifier.put_result(
      {:ok,
       %{
         selected_kind: :surface,
         selected_id: "allbert:workspace",
         confidence: 0.95,
         reason: "Operator asked for the chat surface."
       }}
    )

    assert {:ok, decision} = Engine.decide(EvalFixtures.request(text: "help me orient"))

    assert decision.intent == :open_surface
    assert decision.trace_metadata.classifier.status == :used
    assert decision.trace_metadata.surface_target.path == "/workspace"
  end

  test "unknown classifier proposal falls back to deterministic ranking" do
    enable_fake_classifier!()

    FakeClassifier.put_result(
      {:ok,
       %{
         selected_kind: :action,
         selected_id: "not_registered",
         confidence: 0.95,
         reason: "bad proposal"
       }}
    )

    assert {:ok, decision} = Engine.decide(EvalFixtures.request(text: "what can you do?"))

    assert decision.intent == :registry_action
    assert decision.selected_action == "list_skills"
    assert decision.trace_metadata.classifier.status == :unknown_candidate
  end

  test "low confidence invalid shape and timeout fall back deterministically" do
    enable_fake_classifier!()

    for result <- [
          {:ok, %{selected_kind: :surface, selected_id: "allbert:workspace", confidence: 0.1}},
          {:ok, "not json"},
          {:error, :timeout}
        ] do
      FakeClassifier.put_result(result)

      assert {:ok, decision} = Engine.decide(EvalFixtures.request(text: "what can you do?"))
      assert decision.intent == :registry_action
      assert decision.selected_action == "list_skills"

      assert decision.trace_metadata.classifier.status in [
               :low_confidence,
               :invalid_proposal,
               :rejected
             ]
    end
  end

  test "candidate summary is bounded and redacted" do
    candidates = Engine.collect_candidates(EvalFixtures.request())
    summary = Classifier.candidate_summary(candidates)

    assert length(summary) <= 20

    assert Enum.all?(summary, fn candidate_summary ->
             Enum.all?([:id, :kind, :label, :reason, :score, :source], fn key ->
               Map.has_key?(candidate_summary, key)
             end)
           end)

    refute inspect(summary) =~ "secret"
  end

  test "candidate summary includes bounded descriptor handoff metadata" do
    candidates = Engine.collect_candidates(EvalFixtures.request(text: "analyze CIEN"))
    summary = Classifier.candidate_summary(candidates)

    assert descriptor =
             Enum.find(summary, &(&1.kind == :app_intent and &1.id == "stocksage:run_analysis"))

    assert descriptor.app_id == :stocksage
    assert descriptor.action_name == "run_analysis"
    assert descriptor.confirmation == :required
    assert descriptor.intent_descriptor.required_slots == [:ticker]
    assert descriptor.intent_descriptor.missing_slots == []
    assert descriptor.intent_descriptor.extracted_slots == %{ticker: "CIEN"}
    assert "analyze CIEN" in descriptor.intent_descriptor.examples
    refute inspect(descriptor) =~ "secret"
  end

  test "classifier-selected registered app descriptor selects the registry action" do
    enable_fake_classifier!()

    FakeClassifier.put_result(
      {:ok,
       %{
         selected_kind: :app_intent,
         selected_id: "stocksage:run_analysis",
         confidence: 0.95,
         reason: "Operator asked for financial analysis."
       }}
    )

    assert {:ok, decision} = Engine.decide(EvalFixtures.request(text: "analyze CIEN"))

    assert decision.intent == :registry_action
    assert decision.selected_action == "run_analysis"
    assert decision.trace_metadata.descriptor_candidate_id == "stocksage:run_analysis"
    assert decision.trace_metadata.extracted_slots == %{ticker: "CIEN"}
    assert decision.trace_metadata.classifier.status == :used
    assert decision.trace_metadata.classifier.selected_kind == :app_intent
    assert decision.trace_metadata.classifier.selected_id == "stocksage:run_analysis"
  end

  test "classifier app action proposal that is not collected cannot bypass registry validation" do
    enable_fake_classifier!()

    FakeClassifier.put_result(
      {:ok,
       %{
         selected_kind: :action,
         selected_id: "run_analysis",
         confidence: 0.95,
         reason: "Operator asked for financial analysis."
       }}
    )

    assert {:ok, decision} = Engine.decide(EvalFixtures.request(text: "analyze CIEN"))

    assert decision.intent == :registry_action
    assert decision.selected_action == "run_analysis"
    assert decision.trace_metadata.app_id == :stocksage
    assert decision.trace_metadata.descriptor_candidate_id == "stocksage:run_analysis"
    assert decision.trace_metadata.classifier.status == :unknown_candidate
    assert decision.trace_metadata.classifier.selected_kind == :action
  end

  test "classifier cannot invent an app intent candidate" do
    enable_fake_classifier!()

    FakeClassifier.put_result(
      {:ok,
       %{
         selected_kind: :app_intent,
         selected_id: "stocksage:not_real",
         confidence: 0.95,
         reason: "bad proposal"
       }}
    )

    assert {:ok, decision} = Engine.decide(EvalFixtures.request(text: "analyze CIEN"))

    assert decision.intent == :registry_action
    assert decision.selected_action == "run_analysis"
    assert decision.trace_metadata.descriptor_candidate_id == "stocksage:run_analysis"
    assert decision.trace_metadata.classifier.status == :unknown_candidate
    assert decision.trace_metadata.classifier.selected_kind == :app_intent
    assert decision.trace_metadata.classifier.selected_id == "stocksage:not_real"
  end

  defp enable_fake_classifier! do
    Application.put_env(:allbert_assist, Classifier, classifier: FakeClassifier)

    assert {:ok, _setting} =
             Settings.put(
               "intent.model_assist_enabled",
               true,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )
  end

  defp restore_home(nil), do: System.delete_env("ALLBERT_HOME")
  defp restore_home(value), do: System.put_env("ALLBERT_HOME", value)

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
