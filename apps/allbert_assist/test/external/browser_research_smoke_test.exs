defmodule AllbertAssist.External.BrowserResearchSmokeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  if System.get_env("ALLBERT_BROWSER_EXTERNAL_SMOKE") != "1" do
    @moduletag skip: "set ALLBERT_BROWSER_EXTERNAL_SMOKE=1 to run the real browser smoke"
  end

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings

  @host "allbert-browser-smoke.test"

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_driver = Application.get_env(:allbert_browser, :driver)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-browser-external-smoke-#{System.unique_integer([:positive])}"
      )

    {:ok, server} = start_fixture_server()

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_browser, :driver, AllbertBrowser.Driver.Playwright)

    PluginRegistry.clear()
    assert {:ok, "allbert.browser"} = PluginRegistry.register_module(AllbertBrowser.Plugin)

    ensure_browser_supervisor()
    close_all_sessions()
    assert {:ok, _setting} = Settings.put("browser.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("browser.driver.host_resolver_rules", "MAP #{@host} 127.0.0.1", %{
               audit?: false
             })

    on_exit(fn ->
      close_all_sessions()
      stop_fixture_server(server)
      PluginRegistry.clear()
      restore_default_plugins()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(:allbert_browser, :driver, original_driver)
      File.rm_rf!(root)
    end)

    %{url: "http://#{@host}:#{server.port}/fixture"}
  end

  test "real Playwright driver can doctor, navigate, extract, screenshot, and close", %{url: url} do
    assert {:ok, doctor} = Runner.run("browser_doctor", %{}, %{})
    assert doctor.status == :completed
    assert doctor.doctor.live_check_status == :ok
    assert doctor.doctor.details.driver == "playwright"
    assert doctor.doctor.details.browser == "chromium"

    assert {:ok, started} =
             Runner.run("browser_start_session", %{}, %{confirmation: %{approved?: true}})

    assert {:ok, navigated} =
             Runner.run(
               "browser_navigate",
               %{session_id: started.session_id, url: url},
               %{confirmation: %{approved?: true}}
             )

    assert navigated.status == :completed
    assert navigated.page.url == url
    assert navigated.page.title == "Allbert Browser Smoke"

    assert {:ok, extracted} =
             Runner.run("browser_extract", %{session_id: started.session_id, format: "text"}, %{})

    assert extracted.status == :completed
    assert extracted.extraction.text =~ "Allbert Playwright smoke fixture"
    assert extracted.extraction.cache_ref =~ "cache://browser/#{started.session_id}/"

    assert {:ok, screenshot} =
             Runner.run("browser_screenshot", %{session_id: started.session_id}, %{})

    assert screenshot.status == :completed
    assert screenshot.screenshot.bytes > 0
    assert screenshot.screenshot.screenshot_ref =~ "cache://browser/#{started.session_id}/"

    assert {:ok, closed} =
             Runner.run("browser_close_session", %{session_id: started.session_id}, %{})

    assert closed.status == :completed
    assert {:ok, listed} = Runner.run("browser_list_sessions", %{}, %{})
    assert listed.sessions == []
  end

  defp start_fixture_server do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    parent = self()

    pid =
      spawn_link(fn ->
        send(parent, {:fixture_server_ready, self()})
        accept_loop(listen)
      end)

    receive do
      {:fixture_server_ready, ^pid} -> {:ok, %{listen: listen, pid: pid, port: port}}
    after
      1_000 -> {:error, :fixture_server_start_timeout}
    end
  end

  defp accept_loop(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        _ = :gen_tcp.recv(socket, 0, 5_000)
        :ok = :gen_tcp.send(socket, fixture_response())
        :gen_tcp.close(socket)
        accept_loop(listen)

      {:error, :closed} ->
        :ok
    end
  end

  defp fixture_response do
    body = """
    <!doctype html>
    <html>
      <head><title>Allbert Browser Smoke</title></head>
      <body>
        <main>
          <h1>Allbert Playwright smoke fixture</h1>
          <p>This page is served from a local TCP fixture through a public-looking host mapping.</p>
          <input type="password" value="super-secret-password" />
        </main>
      </body>
    </html>
    """

    [
      "HTTP/1.1 200 OK\r\n",
      "content-type: text/html; charset=utf-8\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ]
  end

  defp stop_fixture_server(%{listen: listen, pid: pid}) do
    :gen_tcp.close(listen)

    if Process.alive?(pid) do
      Process.exit(pid, :normal)
    end
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
