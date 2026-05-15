defmodule AllbertAssist.Actions.SessionActionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Session
  alias AllbertAssist.Settings

  setup do
    original_logger_level = Logger.level()
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    stocksage_registered? = AppRegistry.known_app_id?(:stocksage)
    Logger.configure(level: :info)

    user = "session-action-#{System.unique_integer([:positive])}"

    settings_root =
      Path.join(
        System.tmp_dir!(),
        "allbert-session-actions-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: settings_root)
    ensure_stocksage_plugin!()

    unless stocksage_registered? do
      AppRegistry.register(StockSage.App)
    end

    on_exit(fn ->
      Logger.configure(level: original_logger_level)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(settings_root)
      unless stocksage_registered?, do: AppRegistry.unregister(:stocksage)
      Session.clear(user, "sess-1")
      Session.clear(user, "sess-keys")
      Session.clear(user, "sess-none")
    end)

    {:ok, user: user}
  end

  defp ensure_stocksage_plugin! do
    case PluginRegistry.lookup("stocksage") do
      {:ok, _entry} ->
        :ok

      {:error, :not_found} ->
        assert {:ok, "stocksage"} = PluginRegistry.register_module(StockSage.Plugin)
    end
  end

  test "registered actions set, show, and clear active app through the runner", %{user: user} do
    log =
      capture_log([level: :info], fn ->
        assert {:ok, set_response} =
                 Runner.run(
                   "set_active_app",
                   %{user_id: user, session_id: "sess-1", app_id: "stocksage"},
                   context(user)
                 )

        assert set_response.status == :completed
        assert set_response.session.active_app == :stocksage
        assert set_response.runner_metadata.action_name == "set_active_app"
        assert set_response.runner_metadata.permission_decision.permission == :settings_write

        assert {:ok, show_response} =
                 Runner.run(
                   "show_session_scratchpad",
                   %{user_id: user, session_id: "sess-1"},
                   context(user)
                 )

        assert show_response.status == :completed
        assert show_response.session.active_app == :stocksage
        assert show_response.runner_metadata.permission_decision.permission == :read_only

        assert {:ok, clear_response} =
                 Runner.run(
                   "clear_active_app",
                   %{user_id: user, session_id: "sess-1"},
                   context(user)
                 )

        assert clear_response.status == :completed
        assert clear_response.session.active_app == nil
      end)

    assert log =~ "allbert.action.requested"
    assert log =~ "allbert.action.completed"
  end

  test "unknown app ids and blank identity are rejected without creating entries", %{user: user} do
    assert {:ok, unknown_response} =
             Runner.run(
               "set_active_app",
               %{user_id: user, session_id: "sess-1", app_id: "unknown"},
               context(user)
             )

    assert unknown_response.status == :denied
    assert unknown_response.error == :unknown_app
    assert {:error, :not_found} = Session.get(user, "sess-1")

    assert {:ok, invalid_response} =
             Runner.run(
               "set_active_app",
               %{user_id: "", session_id: "sess-1", app_id: "stocksage"},
               context(user)
             )

    assert invalid_response.status == :denied
    assert invalid_response.error == :invalid_user_id
  end

  test "set action accepts omitted app id as general context", %{user: user} do
    assert {:ok, response} =
             Runner.run(
               "set_active_app",
               %{user_id: user, session_id: "sess-none"},
               context(user)
             )

    assert response.status == :completed
    assert response.session.active_app == nil

    assert {:ok, entry} = Session.get(user, "sess-none")
    assert entry.active_app == nil
  end

  test "show action returns working memory keys without raw values", %{user: user} do
    assert {:ok, _entry} = Session.merge_working_memory(user, "sess-keys", %{pane: "secret-ish"})

    assert {:ok, response} =
             Runner.run(
               "show_session_scratchpad",
               %{user_id: user, session_id: "sess-keys"},
               context(user)
             )

    assert response.status == :completed
    assert response.session.working_memory_keys == ["pane"]
    refute inspect(response) =~ "secret-ish"
  end

  test "clear and show report missing entries as not found", %{user: user} do
    assert {:ok, clear_response} =
             Runner.run(
               "clear_active_app",
               %{user_id: user, session_id: "missing"},
               context(user)
             )

    assert clear_response.status == :not_found
    assert clear_response.error == :not_found

    assert {:ok, show_response} =
             Runner.run(
               "show_session_scratchpad",
               %{user_id: user, session_id: "missing"},
               context(user)
             )

    assert show_response.status == :not_found
    assert show_response.error == :not_found
  end

  defp context(user) do
    %{
      request: %{
        input_signal_id: "input-sig",
        operator_id: user,
        user_id: user,
        channel: :test
      },
      agent: __MODULE__
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
