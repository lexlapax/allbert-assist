defmodule AllbertAssist.Actions.AppActionsTest do
  # v1.0.3 M1 pilot conversion (ADR 0086 contract 3): global_process_serial →
  # pure_async through the ADR 0082 injection seam. Red-first serial-requirement
  # proof (recorded in the plan's M1 Build Progress entry): the pre-conversion
  # file mutated the GLOBAL App/Plugin registries (register-if-absent StockSage,
  # register/unregister UnsortedActionsApp, on_exit ShippedRegistries.restore!),
  # and pointing the two-context proof test below at the global registry pair
  # reproduces the cross-contamination deterministically — context B observes
  # context A's registration, so two tests cannot own the singleton
  # concurrently. Post-conversion every registration lands in a supervised
  # private registry pair (unique pid-qualified names + ETS tables,
  # side_effects: false) and reads resolve through the internal registry
  # context (`%{registry: ...}` on the Runner context map).
  #
  # Logger note (owned, bounded): the log-assertion test enables :info for the
  # ONE emitting module (AllbertAssist.Signals) via Logger.put_module_level/2
  # (deleted on_exit) instead of mutating the VM-wide primary level with
  # Logger.configure/1. No async test in the suite captures logs (verified at
  # conversion), so the override cannot be observed by a concurrent test's
  # assertions.
  use ExUnit.Case, async: true
  @moduletag :pure_async

  import ExUnit.CaptureLog

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Actions.Session.SetActiveApp
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.TestSupport.RegistryIsolationFixtures, as: Fixtures

  defmodule UnsortedActionsApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :unsorted_actions_app

    @impl true
    def display_name, do: "Unsorted Actions App"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def actions, do: [SetActiveApp, DirectAnswer]
  end

  setup do
    registry = Fixtures.start_isolated_registries(:app_actions)
    assert "stocksage" = Fixtures.register_plugin!(registry, StockSage.Plugin)
    assert :stocksage = Fixtures.register_app!(registry, StockSage.App)
    assert :allbert = Fixtures.register_app!(registry, AllbertAssist.App.CoreApp)
    %{registry: registry}
  end

  test "list_apps exposes redacted summaries through the action runner", %{registry: registry} do
    Logger.put_module_level(AllbertAssist.Signals, :info)

    on_exit(fn ->
      Logger.delete_module_level(AllbertAssist.Signals)
    end)

    log =
      capture_log([level: :info], fn ->
        assert {:ok, response} = Runner.run("list_apps", %{}, context(registry))

        assert response.status == :completed
        assert response.runner_metadata.action_name == "list_apps"

        app_ids = Enum.map(response.apps, & &1.app_id)
        assert :allbert in app_ids
        assert :stocksage in app_ids

        assert Enum.all?(response.apps, &Map.has_key?(&1, :action_count))
        refute inspect(response.apps) =~ "skill_paths"
        refute inspect(response.apps) =~ "child_pid"
      end)

    assert log =~ "allbert.action.requested"
    assert log =~ "allbert.action.completed"
  end

  test "show_app returns full registered app detail without supervisor internals", %{
    registry: registry
  } do
    assert {:ok, response} = Runner.run("show_app", %{app_id: "allbert"}, context(registry))

    assert response.status == :completed
    assert response.app.app_id == :allbert
    assert response.app.display_name == "Allbert"
    assert response.app.module == AllbertAssist.App.CoreApp

    assert response.app.action_names == [
             "open_calendar_panel",
             "open_github_panel",
             "open_mail_panel"
           ]

    assert response.app.agent_names == []
    assert response.app.skill_paths == []
    assert response.app.surfaces == []

    assert Enum.any?(
             response.app.provider_surfaces,
             &match?(%{id: :workspace, path: "/workspace"}, &1)
           )

    assert Enum.any?(
             response.app.provider_surfaces,
             &match?(%{id: :core_jobs_panel, kind: :panel}, &1)
           )

    assert {:ok, allbert_entry} = AppRegistry.lookup(:allbert, app_server(registry))
    assert response.app.surface_catalog_count == length(allbert_entry.surface_catalog)
    refute inspect(response.app) =~ "child_pid"
    refute inspect(response.app) =~ "chat-root"
  end

  test "show_app sorts action names for deterministic app inspection", %{registry: registry} do
    assert :unsorted_actions_app = Fixtures.register_app!(registry, UnsortedActionsApp)

    assert {:ok, response} =
             Runner.run("show_app", %{app_id: "unsorted_actions_app"}, context(registry))

    assert response.status == :completed
    assert response.app.action_names == ["direct_answer", "set_active_app"]
  end

  test "show_app reports unknown apps without creating atoms", %{registry: registry} do
    unknown = "__allbert_unknown_app_#{System.unique_integer([:positive])}__"

    assert {:ok, response} = Runner.run("show_app", %{app_id: unknown}, context(registry))

    assert response.status == :not_found
    assert response.error == :unknown_app

    assert_raise ArgumentError, fn ->
      String.to_existing_atom(unknown)
    end
  end

  # ADR 0086 contract-3 two-context negative proof (v1.0.3 M1, release.v103
  # `v103_pilot_global_process`): two injected registry contexts cannot
  # cross-contaminate — an app registered in context A is invisible to
  # context B in BOTH the list_apps and show_app read paths, and vice versa.
  # Pointing both contexts at the global registry pair (the pre-conversion
  # idiom) makes this test RED — the recorded red-first proof of why the
  # file previously required the serial global_process lane.
  test "contract-3 negative proof: two registry contexts cannot cross-contaminate" do
    context_a = Fixtures.start_isolated_registries(:app_actions_ctx_a)
    context_b = Fixtures.start_isolated_registries(:app_actions_ctx_b)

    assert :unsorted_actions_app = Fixtures.register_app!(context_a, UnsortedActionsApp)
    assert :allbert = Fixtures.register_app!(context_b, AllbertAssist.App.CoreApp)

    assert {:ok, a_list} = Runner.run("list_apps", %{}, context(context_a))
    assert {:ok, b_list} = Runner.run("list_apps", %{}, context(context_b))

    assert Enum.map(a_list.apps, & &1.app_id) == [:unsorted_actions_app]
    assert Enum.map(b_list.apps, & &1.app_id) == [:allbert]

    assert {:ok, a_show} =
             Runner.run("show_app", %{app_id: "allbert"}, context(context_a))

    assert a_show.status == :not_found

    assert {:ok, b_show} =
             Runner.run("show_app", %{app_id: "unsorted_actions_app"}, context(context_b))

    assert b_show.status == :not_found
  end

  defp context(registry) do
    %{
      request: %{input_signal_id: "input-sig", operator_id: "local", user_id: "local"},
      registry: registry
    }
  end

  defp app_server(registry), do: registry |> Keyword.fetch!(:app) |> Keyword.take([:server])
end
