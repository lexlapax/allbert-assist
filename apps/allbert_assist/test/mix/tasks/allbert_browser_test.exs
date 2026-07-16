defmodule Mix.Tasks.Allbert.BrowserTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.ShippedRegistries
  alias Mix.Tasks.Allbert.Browser, as: BrowserTask

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_driver = Application.get_env(:allbert_browser, :driver)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-browser-task-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_browser, :driver, AllbertBrowser.Driver.Stub)

    PluginRegistry.clear()
    assert {:ok, "allbert.browser"} = PluginRegistry.register_module(AllbertBrowser.Plugin)
    ensure_browser_supervisor()
    close_all_sessions()
    assert {:ok, _setting} = Settings.put("browser.enabled", true, %{audit?: false})

    on_exit(fn ->
      close_all_sessions()
      ShippedRegistries.restore!()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(:allbert_browser, :driver, original_driver)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "sessions list and close task wrappers call registered browser actions" do
    assert {:ok, _doctor} = Runner.run("browser_doctor", %{}, %{})

    assert {:ok, started} =
             Runner.run("browser_start_session", %{}, %{confirmation: %{approved?: true}})

    assert {:ok, _navigated} =
             Runner.run(
               "browser_navigate",
               %{session_id: started.session_id, url: "https://example.com/task"},
               %{confirmation: %{approved?: true}}
             )

    list_output = capture_io(fn -> BrowserTask.run(["sessions", "list"]) end)
    assert list_output =~ started.session_id
    assert list_output =~ "last_visited_host=example.com"

    close_output =
      capture_io(fn -> BrowserTask.run(["sessions", "close", started.session_id]) end)

    assert close_output =~ "browser session closed: #{started.session_id}"

    relist_output = capture_io(fn -> BrowserTask.run(["sessions", "list"]) end)
    refute relist_output =~ started.session_id
  end

  test "research task runs doctor start navigate extract and close workflow" do
    output =
      capture_io(fn ->
        BrowserTask.run([
          "research",
          "https://example.com/task-research",
          "--extract-format",
          "text"
        ])
      end)

    assert output =~ "browser research completed: cache://browser/"
    assert output =~ "Stub browser extraction for https://example.com/task-research"

    assert {:ok, listed} = Runner.run("browser_list_sessions", %{}, %{})
    assert listed.sessions == []
  end

  defp ensure_browser_supervisor do
    unless Process.whereis(AllbertBrowser.Supervisor) do
      start_supervised!(AllbertBrowser.Supervisor)
    end
  end

  defp close_all_sessions do
    Enum.each(AllbertBrowser.Session.list(), fn %{session_id: session_id} ->
      AllbertBrowser.Session.close(session_id)
    end)
  end

  defp restore_env(module, key, nil), do: Application.delete_env(module, key)
  defp restore_env(module, key, value), do: Application.put_env(module, key, value)
  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
