defmodule AllbertAssist.Intent.ResearchDescriptorTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Extensions.Registry, as: ExtensionsRegistry
  alias AllbertAssist.Intent.Engine
  alias AllbertAssist.Intent.EvalFixtures
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

  setup do
    PluginRegistry.clear()
    AppRegistry.clear()

    assert {:ok, "allbert.research"} = PluginRegistry.register_module(AllbertResearch.Plugin)
    register_app!(AllbertAssist.App.CoreApp, :allbert)
    register_app!(AllbertResearch.App, :allbert_research)

    on_exit(fn ->
      PluginRegistry.clear()
      restore_default_plugins()
      AppRegistry.clear()
      restore_default_apps()
    end)

    :ok
  end

  test "research descriptors are inert metadata, not registered actions" do
    descriptors = ExtensionsRegistry.registered_intent_descriptors()

    assert research = Enum.find(descriptors, &(&1.action_name == "research"))
    assert summarize_url = Enum.find(descriptors, &(&1.action_name == "summarize_url"))

    for descriptor <- [research, summarize_url] do
      assert descriptor.app_id == :allbert_research
      assert descriptor.capability.registered? == false
      assert descriptor.capability.permission == :read_only
      assert descriptor.capability.execution_mode == :read_only
      assert descriptor.capability.confirmation == :not_required
    end

    refute "research" in ActionsRegistry.names()
    refute "summarize_url" in ActionsRegistry.names()
    assert AllbertResearch.Plugin.actions() == []
  end

  test "M3 locked research phrases route to the documented delegate commands" do
    cases = [
      {"research supply chain resilience", "research"},
      {"research https://example.com and summarize", "summarize_url"},
      {"summarize the research on local-first agents", "research"}
    ]

    for {phrase, action_name} <- cases do
      request = EvalFixtures.request(text: phrase, active_app: :allbert)
      candidates = Engine.collect_candidates(request)

      assert candidate =
               Enum.find(
                 candidates,
                 &match?(
                   %{
                     kind: :app_intent,
                     app_id: :allbert_research,
                     action_name: ^action_name
                   },
                   &1
                 )
               )

      assert candidate.trace_metadata.descriptor.capability.registered? == false
      assert candidate.permission == :read_only

      assert {:ok, decision} = Engine.decide(request)

      assert decision.intent == :app_handoff,
             "expected #{phrase} to hand off through #{action_name}, got #{inspect(decision.intent)} with #{inspect(descriptor_scores(candidates))}"

      assert decision.active_app == :allbert
      assert decision.selected_action == nil
      assert decision.trace_metadata.intent_handoff.app_id == :allbert_research
      assert decision.trace_metadata.intent_handoff.action_name == action_name
      assert decision.trace_metadata.intent_handoff.permission == :read_only
    end
  end

  test "active app context does not execute inert research descriptors as actions" do
    assert {:ok, decision} =
             Engine.decide(
               EvalFixtures.request(
                 text: "research supply chain resilience",
                 active_app: :allbert_research
               )
             )

    refute decision.intent == :registry_action
    refute decision.selected_action == "research"
  end

  defp restore_default_apps do
    _ = AppRegistry.register(AllbertAssist.App.CoreApp)
    _ = AppRegistry.register(StockSage.App)
    _ = AppRegistry.register(AllbertNotesFiles.App)
    _ = AppRegistry.register(AllbertBrowser.App)
    _ = AppRegistry.register(AllbertResearch.App)
  end

  defp restore_default_plugins do
    for module <- [
          AllbertAssist.Plugins.Telegram,
          AllbertAssist.Plugins.Email,
          AllbertNotesFiles.Plugin,
          AllbertBrowser.Plugin,
          AllbertResearch.Plugin,
          StockSage.Plugin
        ] do
      _ = PluginRegistry.register_module(module)
    end
  end

  defp register_app!(module, app_id) do
    case AppRegistry.register(module) do
      {:ok, ^app_id} -> :ok
      {:error, {:app_id_taken, ^app_id}} -> :ok
    end
  end

  defp descriptor_scores(candidates) do
    candidates
    |> Enum.filter(&(&1.kind == :app_intent))
    |> Enum.map(&%{app_id: &1.app_id, action_name: &1.action_name, score: &1.score})
  end
end
