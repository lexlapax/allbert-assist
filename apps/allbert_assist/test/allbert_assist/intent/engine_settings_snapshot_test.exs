defmodule AllbertAssist.Intent.EngineSettingsSnapshotTest do
  use AllbertAssist.DataCase, async: false

  # v1.0.2 M8.4: one settings resolution per intent turn. Pre-fix,
  # `Engine.decide/2` re-ran the full `Store.resolved_settings/0` disk
  # read-merge-validate pass (~44-48ms, benchmarked in M8.3) for every flag it
  # reads (descriptors_enabled?, handoff_threshold/margin, clarify_floor,
  # trace/memory flags, max_candidates, classifier + router thresholds, ...).
  # The turn-scoped snapshot pins ONE resolution per decide; this test counts
  # ACTUAL resolution passes via the Store resolution-hook seam (the M8.3
  # composition-read-hook pattern) against a real request fixture.

  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Intent.Engine
  alias AllbertAssist.Intent.EvalFixtures
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.TestSupport.RegistryIsolationFixtures, as: Fixtures

  @resolution_hook_key {Store, :resolution_hook}

  setup do
    registry = Fixtures.start_isolated_registries(:engine_settings_snapshot)

    Fixtures.register_app!(registry, AllbertAssist.App.CoreApp)
    Fixtures.register_app!(registry, AllbertNotesFiles.App)

    Fixtures.register_plugin!(registry, AllbertAssist.Plugins.Telegram)
    Fixtures.register_plugin!(registry, AllbertNotesFiles.Plugin)

    on_exit(fn -> Process.delete(@resolution_hook_key) end)

    %{registry: registry}
  end

  test "decide performs exactly ONE settings resolution per turn", %{registry: registry} do
    counter = install_resolution_counter()

    assert {:ok, %Decision{} = decision} =
             Engine.decide(EvalFixtures.request(text: "tell me a tiny joke"), registry)

    assert decision.intent == :direct_answer

    assert :counters.get(counter, 1) == 1,
           "decide resolved settings #{:counters.get(counter, 1)} times in one turn " <>
             "(expected the turn-scoped snapshot to resolve once)"
  end

  test "decide with an explicit route decision also resolves settings once", %{registry: registry} do
    # Build the route-decision fixture BEFORE installing the counter:
    # Decision.new/1 validates the selected skill, which lazily loads the
    # Skills registry (its own settings reads are outside the intent turn
    # under test).
    assert {:ok, route_decision} =
             Decision.new(%{
               intent: :list_skills,
               selected_action: "list_skills",
               selected_skill: "list-skills",
               context: %{request: EvalFixtures.request()}
             })

    counter = install_resolution_counter()

    request =
      EvalFixtures.request(text: "List the skills you can inspect.")
      |> Map.put(:route_hint, %{
        route: :list_skills,
        explicit?: true,
        source: :intent_agent_predicates
      })
      |> Map.put(:route_decision, route_decision)

    assert {:ok, %Decision{}} = Engine.decide(request, registry)

    assert :counters.get(counter, 1) == 1,
           "explicit-route decide resolved settings #{:counters.get(counter, 1)} times " <>
             "in one turn (expected the turn-scoped snapshot to resolve once)"
  end

  defp install_resolution_counter do
    counter = :counters.new(1, [])
    Process.put(@resolution_hook_key, fn -> :counters.add(counter, 1, 1) end)
    counter
  end
end
