defmodule AllbertAssist.External.BrowserResearchDelegateSmokeTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  if System.get_env("ALLBERT_BROWSER_RESEARCH_DELEGATE_EXTERNAL_SMOKE") != "1" do
    @moduletag skip:
                 "set ALLBERT_BROWSER_RESEARCH_DELEGATE_EXTERNAL_SMOKE=1 to run the real browser research delegate smoke"
  end

  import ExUnit.CaptureIO

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Repo
  alias AllbertAssist.Resources.{Grants, Ref, ResourceURI, Scope}
  alias AllbertAssist.Settings
  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.Allbert.Research, as: ResearchTask

  @host "allbert-research-delegate-smoke.test"

  setup do
    :ok = Sandbox.checkout(Repo)
    Sandbox.mode(Repo, {:shared, self()})

    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_driver = Application.get_env(:allbert_browser, :driver)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-browser-research-delegate-smoke-#{System.unique_integer([:positive])}"
      )

    {:ok, server} = start_fixture_server()

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_browser, :driver, AllbertBrowser.Driver.Playwright)

    PluginRegistry.clear()
    AppRegistry.clear()
    assert {:ok, "allbert.browser"} = PluginRegistry.register_module(AllbertBrowser.Plugin)
    assert {:ok, "allbert.research"} = PluginRegistry.register_module(AllbertResearch.Plugin)
    assert {:ok, :allbert} = AppRegistry.register(AllbertAssist.App.CoreApp)
    assert {:ok, :allbert_browser} = AppRegistry.register(AllbertBrowser.App)
    assert {:ok, :allbert_research} = AppRegistry.register(AllbertResearch.App)

    ensure_browser_supervisor()
    close_all_sessions()
    assert {:ok, _setting} = Settings.put("browser.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("browser.driver.host_resolver_rules", "MAP #{@host} 127.0.0.1", %{
               audit?: false
             })

    assert {:ok, _setting} = Settings.put("research.enabled", true, %{audit?: false})

    on_exit(fn ->
      close_all_sessions()
      stop_fixture_server(server)
      Mix.Task.reenable("allbert.research")
      PluginRegistry.clear()
      restore_default_plugins()
      AppRegistry.clear()
      restore_default_apps()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      restore_env(:allbert_browser, :driver, original_driver)
      File.rm_rf!(root)
    end)

    %{
      url: "http://#{@host}:#{server.port}/fixture",
      grant_prefix: "http://#{@host}:#{server.port}/"
    }
  end

  test "real Playwright driver completes delegated CLI research and closes its session", %{
    url: url,
    grant_prefix: grant_prefix
  } do
    remember_navigation_grant!(grant_prefix)
    Mix.Task.reenable("allbert.research")

    output =
      capture_io(fn ->
        ResearchTask.run([url, "--max-sources=1"])
      end)

    assert output =~ "Allbert research research.specialist"
    assert output =~ "Command: summarize_url"
    assert output =~ "Status: completed"
    assert output =~ "Summary: Research summary from 1 source"
    assert output =~ "Source: #{url}"

    assert {:ok, %{sessions: []}} = Runner.run("browser_list_sessions", %{}, %{})
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
      <head><title>Allbert Research Delegate Smoke</title></head>
      <body>
        <main>
          <h1>Allbert Playwright research delegate smoke fixture</h1>
          <p>This page is served from a local TCP fixture and summarized by research.specialist.</p>
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

  defp restore_default_apps do
    _ = AppRegistry.register(AllbertAssist.App.CoreApp)
    _ = AppRegistry.register(StockSage.App)
    _ = AppRegistry.register(AllbertNotesFiles.App)
    _ = AppRegistry.register(AllbertBrowser.App)
    _ = AppRegistry.register(AllbertResearch.App)
  end

  defp restore_default_plugins do
    _ = PluginRegistry.register_module(StockSage.Plugin)
    _ = PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)
    _ = PluginRegistry.register_module(AllbertAssist.Plugins.Email)
    _ = PluginRegistry.register_module(AllbertNotesFiles.Plugin)
    _ = PluginRegistry.register_module(AllbertBrowser.Plugin)
    _ = PluginRegistry.register_module(AllbertResearch.Plugin)
  end

  defp restore_env(module, key, nil), do: Application.delete_env(module, key)
  defp restore_env(module, key, value), do: Application.put_env(module, key, value)
  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
