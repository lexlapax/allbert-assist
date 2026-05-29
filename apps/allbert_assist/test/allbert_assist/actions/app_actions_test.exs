defmodule AllbertAssist.Actions.AppActionsTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  import ExUnit.CaptureLog

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Actions.Session.SetActiveApp
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

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
    ensure_stocksage_app!()
    :ok
  end

  test "list_apps exposes redacted summaries through the action runner" do
    original_logger_level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: original_logger_level)
    end)

    log =
      capture_log([level: :info], fn ->
        assert {:ok, response} = Runner.run("list_apps", %{}, context())

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

  test "show_app returns full registered app detail without supervisor internals" do
    assert {:ok, response} = Runner.run("show_app", %{app_id: "allbert"}, context())

    assert response.status == :completed
    assert response.app.app_id == :allbert
    assert response.app.display_name == "Allbert"
    assert response.app.module == AllbertAssist.App.CoreApp
    assert response.app.action_names == []
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

    assert response.app.surface_catalog_count == 51
    refute inspect(response.app) =~ "child_pid"
    refute inspect(response.app) =~ "chat-root"
  end

  test "show_app sorts action names for deterministic app inspection" do
    on_exit(fn -> AppRegistry.unregister(:unsorted_actions_app) end)

    assert {:ok, :unsorted_actions_app} = AppRegistry.register(UnsortedActionsApp)
    assert {:ok, response} = Runner.run("show_app", %{app_id: "unsorted_actions_app"}, context())

    assert response.status == :completed
    assert response.app.action_names == ["direct_answer", "set_active_app"]
  end

  test "show_app reports unknown apps without creating atoms" do
    unknown = "__allbert_unknown_app_#{System.unique_integer([:positive])}__"

    assert {:ok, response} = Runner.run("show_app", %{app_id: unknown}, context())

    assert response.status == :not_found
    assert response.error == :unknown_app

    assert_raise ArgumentError, fn ->
      String.to_existing_atom(unknown)
    end
  end

  defp context do
    %{request: %{input_signal_id: "input-sig", operator_id: "local", user_id: "local"}}
  end

  defp ensure_stocksage_app! do
    case AppRegistry.lookup(:stocksage) do
      {:ok, _entry} ->
        :ok

      {:error, :not_found} ->
        PluginRegistry.register_module(StockSage.Plugin)
        assert {:ok, :stocksage} = AppRegistry.register(StockSage.App)
        on_exit(fn -> AppRegistry.unregister(:stocksage) end)
    end
  end
end
