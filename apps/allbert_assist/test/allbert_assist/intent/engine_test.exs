defmodule AllbertAssist.Intent.EngineTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Intent.Engine
  alias AllbertAssist.Intent.EvalFixtures
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Compiler
  alias AllbertAssist.Objectives
  alias AllbertAssist.Plugin.Entry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings

  defmodule PluginEcho do
    use Jido.Action,
      name: "plugin_echo_v019",
      description: "Echo from an intent engine plugin fixture.",
      schema: [text: [type: :string, required: false]]

    def capability do
      %{
        permission: :read_only,
        exposure: :agent,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required
      }
    end

    @impl true
    def run(params, _context), do: {:ok, Map.put(params, :status, :completed)}
  end

  setup do
    original_plugins = PluginRegistry.registered_plugins()
    original_diagnostics = PluginRegistry.diagnostics()

    PluginRegistry.clear()

    assert {:ok, "allbert.telegram"} =
             PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)

    assert {:ok, "allbert.email"} = PluginRegistry.register_module(AllbertAssist.Plugins.Email)
    assert {:ok, "stocksage"} = PluginRegistry.register_module(StockSage.Plugin)

    app_registered? = AppRegistry.known_app_id?(:stocksage)

    unless app_registered? do
      assert {:ok, :stocksage} = AppRegistry.register(StockSage.App)
    end

    on_exit(fn ->
      PluginRegistry.clear()
      Enum.each(original_plugins, &PluginRegistry.register_entry/1)
      unless app_registered?, do: AppRegistry.unregister(:stocksage)

      Enum.each(original_diagnostics, fn {plugin_id, diagnostics} ->
        PluginRegistry.put_diagnostics(plugin_id, diagnostics)
      end)
    end)

    :ok
  end

  test "decide returns the v0.11 decision shape for a direct-answer turn" do
    assert {:ok, decision} = Engine.decide(EvalFixtures.request(text: "tell me a tiny joke"))

    assert %Decision{} = decision
    assert decision.intent == :direct_answer
    assert decision.selected_action == "direct_answer"
    assert decision.trace_metadata.intent_candidates.selected.kind == :action
    assert decision.trace_metadata.intent_candidates.selected.id == "direct_answer"
    assert decision.trace_metadata.intent_candidates.total > 1
    assert decision.trace_metadata.intent_candidates.engine_version == "v0.19"
  end

  test "decide preserves a deterministic route decision as the engine-selected route" do
    assert {:ok, decision} =
             Decision.new(%{
               intent: :list_skills,
               selected_action: "list_skills",
               selected_skill: "list-skills",
               context: %{request: EvalFixtures.request()}
             })

    request =
      EvalFixtures.request(text: "List the skills you can inspect.")
      |> Map.put(:route_hint, %{
        route: :list_skills,
        explicit?: true,
        source: :intent_agent_predicates
      })
      |> Map.put(:route_decision, decision)

    assert {:ok, selected} = Engine.decide(request)

    assert selected.selected_action == "list_skills"
    assert selected.trace_metadata.intent_candidates.selected.id == "list_skills"
    assert selected.trace_metadata.intent_candidates.selected.trace_metadata.engine_route_hint?
    assert selected.trace_metadata.intent_candidates.total > 1
  end

  test "put_candidate_metadata annotates existing decisions without changing selected action" do
    assert {:ok, decision} =
             Decision.new(%{
               intent: :list_skills,
               selected_action: "list_skills",
               selected_skill: "list-skills",
               context: %{request: EvalFixtures.request()}
             })

    annotated = Engine.put_candidate_metadata(decision)

    assert annotated.selected_action == "list_skills"
    assert annotated.trace_metadata.intent_candidates.selected.id == "list_skills"
    assert annotated.trace_metadata.intent_candidates.total > 1
  end

  test "collects registry-driven action skill and surface candidates" do
    candidates = Engine.collect_candidates(EvalFixtures.request())

    assert Enum.any?(candidates, &match?(%{kind: :action, action_name: "direct_answer"}, &1))
    assert Enum.any?(candidates, &match?(%{kind: :skill, skill_name: "direct-answer"}, &1))
    assert Enum.any?(candidates, &match?(%{kind: :surface, app_id: :allbert}, &1))
    assert length(candidates) <= 80
  end

  test "neutral app intent descriptor produces handoff without executing app action" do
    request = EvalFixtures.request(text: "analyze CIEN", active_app: :allbert)
    candidates = Engine.collect_candidates(request)

    assert descriptor =
             Enum.find(
               candidates,
               &match?(%{kind: :app_intent, app_id: :stocksage, action_name: "run_analysis"}, &1)
             )

    assert descriptor.score >= 0.6
    assert descriptor.trace_metadata.extracted_slots == %{ticker: "CIEN"}
    assert descriptor.trace_metadata.missing_slots == []

    assert {:ok, decision} = Engine.decide(request)
    assert decision.intent == :app_handoff
    refute decision.selected_action == "run_analysis"
    assert decision.active_app == :allbert
    assert decision.trace_metadata.intent_handoff.app_id == :stocksage
    assert decision.trace_metadata.intent_handoff.action_name == "run_analysis"
    assert decision.trace_metadata.intent_handoff.extracted_slots == %{"ticker" => "CIEN"}

    assert Enum.any?(
             decision.trace_metadata.intent_candidates.descriptors,
             &(&1.app_id == :stocksage and &1.action_name == "run_analysis")
           )
  end

  test "missing app descriptor slots ask for clarification" do
    assert {:ok, decision} =
             Engine.decide(EvalFixtures.request(text: "analyze", active_app: :allbert))

    assert decision.intent == :clarify_intent
    refute decision.selected_action == "run_analysis"
    assert decision.trace_metadata.intent_handoff.action_name == "run_analysis"
    assert decision.trace_metadata.intent_handoff.missing_slots == ["ticker"]
  end

  test "descriptor handoff can be disabled through Settings Central" do
    on_exit(fn -> Settings.put("intent.descriptors_enabled", true, %{audit?: false}) end)

    assert {:ok, _setting} = Settings.put("intent.descriptors_enabled", false, %{audit?: false})

    assert {:ok, decision} =
             Engine.decide(EvalFixtures.request(text: "analyze CIEN", active_app: :allbert))

    assert decision.intent == :direct_answer
    assert decision.selected_action == "direct_answer"
  end

  test "plugin-contributed action candidates carry plugin provenance" do
    assert {:ok, "example.intent_engine"} =
             PluginRegistry.register_entry(%PluginEntry{
               plugin_id: "example.intent_engine",
               display_name: "Intent Engine Plugin",
               version: "0.1.0",
               kind: "actions",
               source: :project,
               status: :enabled,
               trust_status: :trusted,
               actions: [PluginEcho]
             })

    assert Enum.any?(
             Engine.collect_candidates(EvalFixtures.request(text: "run plugin echo v019")),
             &match?(
               %{
                 kind: :action,
                 action_name: "plugin_echo_v019",
                 source: :plugin,
                 plugin_id: "example.intent_engine"
               },
               &1
             )
           )
  end

  test "collects channel memory and refusal candidates" do
    assert Enum.any?(AllbertAssist.Channels.list_channels(), &(&1.channel == "telegram"))

    candidates =
      Engine.collect_candidates(
        EvalFixtures.request(text: "Remember this and show my telegram channels")
      )

    assert Enum.any?(
             candidates,
             &match?(
               %{kind: :channel, channel_id: "telegram", plugin_id: "allbert.telegram"},
               &1
             )
           )

    assert Enum.any?(candidates, &match?(%{kind: :memory, id: "markdown_memory:append"}, &1))

    refusal_candidates =
      Engine.collect_candidates(EvalFixtures.request(text: "Read local file ./mix.exs"))

    assert Enum.any?(refusal_candidates, &match?(%{kind: :refusal}, &1))
  end

  test "collect_candidates/2 includes objective candidates only when requested" do
    registered? = AppRegistry.known_app_id?(:stocksage)

    unless registered? do
      assert {:ok, "stocksage"} = PluginRegistry.register_module(StockSage.Plugin)
      assert {:ok, :stocksage} = AppRegistry.register(StockSage.App)
    end

    on_exit(fn -> unless registered?, do: AppRegistry.unregister(:stocksage) end)

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Analyze AAPL",
               objective: "Complete one StockSage analysis for AAPL.",
               active_app: "stocksage"
             })

    request = EvalFixtures.request(text: "continue the AAPL objective", user_id: "alice")

    refute Enum.any?(Engine.collect_candidates(request), &(&1.kind == :objective))

    candidates = Engine.collect_candidates(request, objective: true)

    assert %{kind: :objective, id: id, source: :objective, app_id: :stocksage} =
             Enum.find(candidates, &(&1.kind == :objective))

    assert id == objective.id
  end

  test "collects index-backed markdown memory candidates without bodies or secrets" do
    with_memory_home(fn ->
      assert {:ok, _entry} =
               Memory.append(%{
                 category: :preferences,
                 body: "Alice prefers concise release notes and no token=abc123 in output.",
                 actor: "alice",
                 agent: "test",
                 channel: :test,
                 source_signal_id: "sig"
               })

      assert {:ok, _result} = Compiler.compile_index(Memory.root())

      candidates =
        Engine.collect_candidates(
          EvalFixtures.request(text: "recall concise release notes", user_id: "alice")
        )

      assert %{trace_metadata: trace_metadata} =
               Enum.find(candidates, fn candidate ->
                 candidate.kind == :memory and
                   String.starts_with?(candidate.id, "markdown_memory:/")
               end)

      assert trace_metadata.category == :preferences
      assert trace_metadata.review_status == :unreviewed
      assert is_binary(trace_metadata.timestamp)
      assert is_binary(trace_metadata.path)
      assert "keyword:concise" in trace_metadata.match_reasons
      refute Map.has_key?(trace_metadata, :body)
      refute inspect(trace_metadata) =~ "abc123"
    end)
  end

  test "does not collect flagged prune-nominated disabled or stale memory index entries" do
    with_memory_home(fn ->
      assert {:ok, flagged} =
               Memory.append(%{
                 category: :notes,
                 body: "Alice flagged memory about quarterly launch notes.",
                 actor: "alice",
                 agent: "test",
                 channel: :test,
                 source_signal_id: "sig"
               })

      assert {:ok, _pruned} =
               Memory.append(%{
                 category: :notes,
                 body: "Alice prune nominated memory about launch notes.",
                 actor: "alice",
                 agent: "test",
                 channel: :test,
                 source_signal_id: "sig"
               })

      assert {:ok, _flagged} =
               Memory.review_entry(flagged.path, %{status: :flagged, reviewed_by: "alice"},
                 user_id: "alice"
               )

      assert {:ok, [pruned]} =
               Memory.list_entries(user_id: "alice", limit: 10)
               |> then(fn {:ok, entries} ->
                 {:ok, Enum.reject(entries, &(&1.path == flagged.path))}
               end)

      assert {:ok, _prune_nominated} =
               Memory.review_entry(pruned.path, %{status: :prune_nominated, reviewed_by: "alice"},
                 user_id: "alice"
               )

      assert {:ok, _result} = Compiler.compile_index(Memory.root())

      request = EvalFixtures.request(text: "recall launch notes", user_id: "alice")
      refute indexed_memory_candidate?(Engine.collect_candidates(request))

      assert {:ok, active} =
               Memory.append(%{
                 category: :notes,
                 body: "Alice active memory about launch notes.",
                 actor: "alice",
                 agent: "test",
                 channel: :test,
                 source_signal_id: "sig"
               })

      assert {:ok, _kept} =
               Memory.review_entry(active.path, %{status: :kept, reviewed_by: "alice"},
                 user_id: "alice"
               )

      refute indexed_memory_candidate?(Engine.collect_candidates(request))

      assert {:ok, _result} = Compiler.compile_index(Memory.root())
      assert indexed_memory_candidate?(Engine.collect_candidates(request))

      assert {:ok, _setting} = Settings.put("memory.index_enabled", false, %{audit?: false})
      refute indexed_memory_candidate?(Engine.collect_candidates(request))
    end)
  end

  test "candidate metadata includes rejected registry candidates" do
    assert {:ok, decision} =
             Decision.new(%{
               intent: :list_skills,
               selected_action: "list_skills",
               selected_skill: "list-skills",
               context: %{request: EvalFixtures.request()}
             })

    annotated = Engine.put_candidate_metadata(decision, %{request: EvalFixtures.request()})

    assert %{rejected: rejected} = annotated.trace_metadata.intent_candidates
    assert Enum.any?(rejected, &(&1.kind == :action and &1.id == "direct_answer"))
  end

  test "candidate metadata can hide rejected candidates through settings" do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths = Application.get_env(:allbert_assist, AllbertAssist.Paths)
    original_settings = Application.get_env(:allbert_assist, AllbertAssist.Settings)

    home =
      Path.join(System.tmp_dir!(), "allbert-engine-test-#{System.unique_integer([:positive])}")

    System.put_env("ALLBERT_HOME", home)
    Application.delete_env(:allbert_assist, AllbertAssist.Paths)
    Application.delete_env(:allbert_assist, AllbertAssist.Settings)

    on_exit(fn ->
      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      restore_env(AllbertAssist.Paths, original_paths)
      restore_env(AllbertAssist.Settings, original_settings)
      File.rm_rf!(home)
    end)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.trace_rejected_candidates", false, %{
               audit?: false
             })

    assert {:ok, decision} =
             Decision.new(%{
               intent: :list_skills,
               selected_action: "list_skills",
               selected_skill: "list-skills",
               context: %{request: EvalFixtures.request()}
             })

    annotated = Engine.put_candidate_metadata(decision, %{request: EvalFixtures.request()})

    assert annotated.trace_metadata.intent_candidates.rejected == []
  end

  test "decide returns inert surface navigation when a registered surface matches" do
    assert {:ok, decision} =
             Engine.decide(EvalFixtures.request(text: "Open Allbert chat for me"))

    assert decision.intent == :open_surface
    assert decision.selected_action == nil
    assert decision.selected_skill == nil
    assert decision.trace_metadata.surface_target.path == "/workspace"
    assert decision.trace_metadata.intent_candidates.selected.kind == :surface
    assert decision.trace_metadata.intent_candidates.selected.surface_id == "workspace"
  end

  test "unknown active app falls back to allbert without creating atoms" do
    unknown = "__allbert_unknown_app_#{System.unique_integer([:positive])}__"

    assert {:ok, decision} =
             Engine.decide(EvalFixtures.request(text: "what can you do?", active_app: unknown))

    assert decision.active_app == :allbert
    assert %{kind: :unknown_app_id, fallback: :allbert} = hd(decision.diagnostics)

    assert_raise ArgumentError, fn ->
      String.to_existing_atom(unknown)
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp with_memory_home(fun) do
    original_paths = Application.get_env(:allbert_assist, AllbertAssist.Paths)
    original_memory = Application.get_env(:allbert_assist, Memory)
    original_settings = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(System.tmp_dir!(), "allbert-engine-memory-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, AllbertAssist.Paths, home: home)
    Application.put_env(:allbert_assist, Memory, root: Path.join(home, "memory"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    try do
      fun.()
    after
      restore_env(AllbertAssist.Paths, original_paths)
      restore_env(Memory, original_memory)
      restore_env(Settings, original_settings)
      File.rm_rf!(home)
    end
  end

  defp indexed_memory_candidate?(candidates) do
    Enum.any?(candidates, fn candidate ->
      candidate.kind == :memory and String.starts_with?(candidate.id, "markdown_memory:/")
    end)
  end
end
