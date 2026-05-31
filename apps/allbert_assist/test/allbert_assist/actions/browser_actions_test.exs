defmodule AllbertAssist.Actions.BrowserActionsTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_driver = Application.get_env(:allbert_browser, :driver)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-browser-actions-#{System.unique_integer([:positive])}"
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
      PluginRegistry.clear()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(:allbert_browser, :driver, original_driver)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "doctor live check persists ok state and start session requires approval" do
    assert {:ok, doctor} = Runner.run("browser_doctor", %{}, %{})
    assert doctor.status == :completed
    assert doctor.doctor.live_check_status == :ok

    assert {:ok, pending} = Runner.run("browser_start_session", %{}, %{})
    assert pending.status == :needs_confirmation
    assert is_binary(pending.confirmation_id)

    assert {:ok, started} =
             Runner.run("browser_start_session", %{}, %{confirmation: %{approved?: true}})

    assert started.status == :completed
    assert is_binary(started.session_id)
  end

  test "navigate, extract, and screenshot use the stub driver after approval" do
    assert {:ok, _doctor} = Runner.run("browser_doctor", %{}, %{})

    assert {:ok, started} =
             Runner.run("browser_start_session", %{}, %{confirmation: %{approved?: true}})

    assert {:ok, navigated} =
             Runner.run(
               "browser_navigate",
               %{session_id: started.session_id, url: "https://example.com/status"},
               %{confirmation: %{approved?: true}}
             )

    assert navigated.status == :completed
    assert navigated.page.url == "https://example.com/status"

    assert {:ok, extracted} =
             Runner.run("browser_extract", %{session_id: started.session_id, format: "text"}, %{})

    assert extracted.status == :completed
    assert extracted.extraction.text =~ "Stub browser extraction"

    assert {:ok, screenshot} =
             Runner.run("browser_screenshot", %{session_id: started.session_id}, %{})

    assert screenshot.status == :completed
    assert screenshot.screenshot.redacted_credential_inputs?
  end

  test "navigation preflight denies private hosts before session call" do
    assert {:ok, _doctor} = Runner.run("browser_doctor", %{}, %{})

    assert {:ok, response} =
             Runner.run(
               "browser_navigate",
               %{session_id: "missing", url: "https://127.0.0.1/status"},
               %{confirmation: %{approved?: true}}
             )

    assert response.status == :denied
    assert response.error == {:private_host_denied, "127.0.0.1"}
  end

  test "network policy allows same-origin subresources and denies cross-origin/private hosts" do
    assert AllbertBrowser.NetworkPolicy.allow_subresource?(
             "https://example.com/page",
             "https://example.com/app.js"
           )

    refute AllbertBrowser.NetworkPolicy.allow_subresource?(
             "https://example.com/page",
             "https://cdn.example.net/app.js"
           )

    refute AllbertBrowser.NetworkPolicy.allow_subresource?(
             "https://example.com/page",
             "https://127.0.0.1/app.js"
           )
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
