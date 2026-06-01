defmodule AllbertAssist.Actions.BrowserActionsTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.ResourceMetadata
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
      restore_default_plugins()
      restore_default_apps()
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
    assert extracted.extraction.cache_ref =~ "cache://browser/#{started.session_id}/"

    assert {:ok, screenshot} =
             Runner.run("browser_screenshot", %{session_id: started.session_id}, %{})

    assert screenshot.status == :completed
    assert screenshot.screenshot.redacted_credential_inputs?
    assert screenshot.screenshot.screenshot_ref =~ "cache://browser/#{started.session_id}/"

    assert {:ok, listed} = Runner.run("browser_list_sessions", %{}, %{})
    assert [%{session_id: session_id, last_visited_host: "example.com"}] = listed.sessions
    assert session_id == started.session_id

    assert {:ok, closed} =
             Runner.run("browser_close_session", %{session_id: started.session_id}, %{})

    assert closed.status == :completed
    assert {:ok, relisted} = Runner.run("browser_list_sessions", %{}, %{})
    assert relisted.sessions == []
  end

  test "click requires confirmation with selector and bounded visible label preview" do
    assert {:ok, _doctor} = Runner.run("browser_doctor", %{}, %{})

    assert {:ok, started} =
             Runner.run("browser_start_session", %{}, %{confirmation: %{approved?: true}})

    assert {:ok, _navigated} =
             Runner.run(
               "browser_navigate",
               %{session_id: started.session_id, url: "https://example.com/click"},
               %{confirmation: %{approved?: true}}
             )

    label = String.duplicate("Launch ", 40)

    assert {:ok, pending} =
             Runner.run(
               "browser_click",
               %{
                 session_id: started.session_id,
                 selector: "button.launch",
                 visible_label_preview: label
               },
               %{}
             )

    assert pending.status == :needs_confirmation
    assert pending.confirmation["params_summary"]["selector"] == "button.launch"
    assert String.length(pending.confirmation["params_summary"]["visible_label_preview"]) == 200

    assert ResourceMetadata.lines(pending.confirmation)
           |> Enum.any?(&String.contains?(&1, "Browser selector"))

    assert {:ok, clicked} =
             Runner.run(
               "browser_click",
               %{
                 session_id: started.session_id,
                 selector: "button.launch",
                 visible_label_preview: label
               },
               %{confirmation: %{approved?: true}}
             )

    assert clicked.status == :completed
    assert clicked.click.selector == "button.launch"
  end

  test "form fill and download deny by default and require confirmation after opt-in" do
    assert {:ok, _doctor} = Runner.run("browser_doctor", %{}, %{})

    assert {:ok, started} =
             Runner.run("browser_start_session", %{}, %{confirmation: %{approved?: true}})

    assert {:ok, denied_fill} =
             Runner.run(
               "browser_fill",
               %{session_id: started.session_id, selector: "input[name=email]", value: "raw"},
               %{}
             )

    assert denied_fill.status == :denied
    assert denied_fill.error == :browser_form_fill_disabled

    assert {:ok, denied_download} =
             Runner.run(
               "browser_download",
               %{session_id: started.session_id, url: "https://example.com/file.pdf"},
               %{}
             )

    assert denied_download.status == :denied
    assert denied_download.error == :browser_download_disabled

    assert {:ok, _setting} = Settings.put("browser.form_fill.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("browser.download.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("permissions.browser_form_fill", "needs_confirmation", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("permissions.browser_download", "needs_confirmation", %{audit?: false})

    assert {:ok, pending_fill} =
             Runner.run(
               "browser_fill",
               %{
                 session_id: started.session_id,
                 selector: "input[name=email]",
                 value: "raw@example.com"
               },
               %{}
             )

    assert pending_fill.status == :needs_confirmation
    assert pending_fill.confirmation["params_summary"]["value_redacted?"]

    assert {:ok, filled} =
             Runner.run(
               "browser_fill",
               %{
                 session_id: started.session_id,
                 selector: "input[name=email]",
                 value: "raw@example.com"
               },
               %{confirmation: %{approved?: true}}
             )

    assert filled.status == :completed
    assert filled.fill.value_redacted?

    assert {:ok, pending_download} =
             Runner.run(
               "browser_download",
               %{session_id: started.session_id, url: "https://example.com/file.pdf"},
               %{}
             )

    assert pending_download.status == :needs_confirmation

    assert {:ok, downloaded} =
             Runner.run(
               "browser_download",
               %{
                 session_id: started.session_id,
                 url: "https://example.com/file.pdf",
                 filename: "file.pdf"
               },
               %{confirmation: %{approved?: true}}
             )

    assert downloaded.status == :completed
    assert downloaded.download.download_ref =~ "cache://browser/#{started.session_id}/"
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

  defp restore_default_apps do
    _ = AllbertAssist.App.Registry.clear()
    _ = AllbertAssist.App.Registry.register(AllbertAssist.App.CoreApp)
    _ = AllbertAssist.App.Registry.register(StockSage.App)
  end

  defp restore_default_plugins do
    _ = PluginRegistry.register_module(StockSage.Plugin)
    _ = PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)
    _ = PluginRegistry.register_module(AllbertAssist.Plugins.Email)
  end

  defp restore_env(module, key, nil), do: Application.delete_env(module, key)
  defp restore_env(module, key, value), do: Application.put_env(module, key, value)
  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
