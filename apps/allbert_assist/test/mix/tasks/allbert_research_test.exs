defmodule Mix.Tasks.Allbert.ResearchTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :home_fs_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Objectives
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Resources.{Grants, Ref, ResourceURI, Scope}
  alias AllbertAssist.Settings
  alias AllbertBrowser.Session
  alias Mix.Tasks.Allbert.Research, as: ResearchTask

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_driver = Application.get_env(:allbert_browser, :driver)
    previous_halt = Application.get_env(:allbert_assist, ResearchTask)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-research-task-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_browser, :driver, AllbertBrowser.Driver.Stub)

    Application.put_env(:allbert_assist, ResearchTask,
      halt_fun: fn code -> throw({:halt, code}) end
    )

    PluginRegistry.clear()
    AppRegistry.clear()
    assert {:ok, "allbert.browser"} = PluginRegistry.register_module(AllbertBrowser.Plugin)
    assert {:ok, "allbert.research"} = PluginRegistry.register_module(AllbertResearch.Plugin)
    register_app!(AllbertAssist.App.CoreApp, :allbert)
    register_app!(AllbertResearch.App, :allbert_research)

    ensure_browser_supervisor()
    ensure_research_supervisor()
    close_all_sessions()

    assert {:ok, _setting} = Settings.put("browser.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("research.enabled", true, %{audit?: false})

    Mix.Task.reenable("allbert.research")

    on_exit(fn ->
      close_all_sessions()
      Mix.Task.reenable("allbert.research")
      PluginRegistry.clear()
      restore_default_plugins()
      AppRegistry.clear()
      restore_default_apps()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(:allbert_browser, :driver, original_driver)

      if previous_halt do
        Application.put_env(:allbert_assist, ResearchTask, previous_halt)
      else
        Application.delete_env(:allbert_assist, ResearchTask)
      end

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "runs grant-backed delegated URL research from the CLI" do
    remember_navigation_grant!("https://example.com/docs/")

    output =
      capture_io(fn ->
        ResearchTask.run(["https://example.com/docs/a", "--max-sources=1"])
      end)

    assert output =~ "Allbert research research.specialist"
    assert output =~ "Command: summarize_url"
    assert output =~ "Status: completed"
    assert output =~ "Summary: Research summary from 1 source"
    assert output =~ "Source: https://example.com/docs/a"

    assert {:ok, %{sessions: []}} = Runner.run("browser_list_sessions", %{}, %{})

    assert [%{status: "completed", source_intent: "mix allbert.research"}] =
             Objectives.list_objectives("local", status: "completed", limit: 1)
  end

  test "ungranted delegated URL research prints the pending navigation confirmation" do
    output =
      capture_io(fn ->
        ResearchTask.run(["https://example.com/docs/pending", "--max-sources=1"])
      end)

    assert output =~ "Allbert research research.specialist"
    assert output =~ "Command: summarize_url"
    assert output =~ "Status: needs_confirmation"
    assert output =~ "Confirmation: "
    assert output =~ "Research summarize_url is waiting for browser_navigate confirmation."

    assert [%{status: "blocked", source_intent: "mix allbert.research"}] =
             Objectives.list_objectives("local", status: "blocked", limit: 1)
  end

  defp remember_navigation_grant!(url) do
    {:ok, resource_uri} = ResourceURI.url(url, :prefix)

    {:ok, ref} =
      Ref.new(%{
        resource_uri: resource_uri,
        origin_kind: :remote_url,
        operation_class: :browser_navigate,
        access_mode: :fetch,
        scope: Scope.url_prefix(resource_uri),
        downstream_consumer: :browser_navigator
      })

    assert {:ok, _grant} = Grants.remember(ref, audit?: false)
  end

  defp ensure_browser_supervisor do
    unless Process.whereis(AllbertBrowser.Supervisor) do
      start_supervised!(AllbertBrowser.Supervisor)
    end
  end

  defp ensure_research_supervisor do
    if Process.whereis(AllbertResearch.Supervisor) do
      AllbertResearch.Runtime.register_if_available(AllbertResearch.Agent, AllbertResearch.Agent)
    else
      start_supervised!(AllbertResearch.Supervisor)
    end
  end

  defp close_all_sessions do
    Enum.each(Session.list(), fn %{session_id: session_id} ->
      Session.close(session_id)
    end)
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

  defp restore_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_env(key, value), do: Application.put_env(:allbert_assist, key, value)
  defp restore_env(module, key, nil), do: Application.delete_env(module, key)
  defp restore_env(module, key, value), do: Application.put_env(module, key, value)
end
