defmodule AllbertAssist.Actions.BrowserM3Test do
  use AllbertAssist.DataCase, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings
  alias AllbertAssist.Surface
  alias AllbertBrowser.{Cache, Extractors}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_driver = Application.get_env(:allbert_browser, :driver)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-browser-m3-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_browser, :driver, AllbertBrowser.Driver.Stub)

    PluginRegistry.clear()
    AppRegistry.clear()
    assert {:ok, "allbert.browser"} = PluginRegistry.register_module(AllbertBrowser.Plugin)
    assert {:ok, :allbert_browser} = AppRegistry.register(AllbertBrowser.App)

    on_exit(fn ->
      PluginRegistry.clear()
      restore_default_plugins()
      AppRegistry.clear()
      restore_default_apps()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(:allbert_browser, :driver, original_driver)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "markdown extractor preserves headings lists and code blocks" do
    html = """
    <h1>Title</h1>
    <p>Intro &amp; body.</p>
    <ul><li>One</li><li>Two</li></ul>
    <pre><code>IO.puts("ok")</code></pre>
    """

    assert {:ok, extraction} = Extractors.extract(:markdown, html, max_bytes: 4096)
    assert extraction.format == :markdown
    assert extraction.text =~ "# Title"
    assert extraction.text =~ "- One"
    assert extraction.text =~ "IO.puts(\"ok\")"
    assert extraction.text =~ "```"
  end

  test "pdf extractor enforces bounded local text-layer parsing" do
    pdf = """
    %PDF-1.4
    1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
    2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
    3 0 obj << /Type /Page /Parent 2 0 R /Contents 4 0 R >> endobj
    4 0 obj << /Length 48 >> stream
    BT (Hello PDF) Tj [( text) 20 ( layer)] TJ ET
    endstream endobj
    %%EOF
    """

    opts = [max_bytes: 8, pdf_max_pages: 5, pdf_parse_timeout_ms: 1_000]
    assert {:ok, extraction} = Extractors.extract(:pdf, pdf, opts)
    assert extraction.format == :pdf
    assert extraction.text == "Hello PD"
    assert extraction.truncated?

    assert {:error, :malformed_pdf} = Extractors.extract(:pdf, "not pdf", opts)
    assert {:error, :encrypted_pdf} = Extractors.extract(:pdf, "%PDF\n/Encrypt\n", opts)

    assert {:error, :pdf_parse_timeout} =
             Extractors.extract(:pdf, pdf, Keyword.put(opts, :pdf_parse_timeout_ms, 0))

    too_many_pages = "%PDF\n" <> String.duplicate("/Type /Page\n", 3) <> "(x) Tj"

    assert {:error, :pdf_page_cap_exceeded} =
             Extractors.extract(:pdf, too_many_pages, Keyword.put(opts, :pdf_max_pages, 2))
  end

  test "cache stores artifacts under browser session roots and sweeps expired files" do
    assert {:ok, artifact} =
             Cache.put("session-1", "extraction", "cached text",
               ext: ".txt",
               metadata: %{format: "text", preview: "cached text"}
             )

    assert artifact.ref =~ "cache://browser/session-1/"
    assert File.exists?(artifact.path)
    assert [%{preview: "cached text"}] = Cache.latest_artifacts(limit: 1)

    assert {:ok, 1} = Cache.sweep_expired(max_age_ms: 0)
    refute File.exists?(artifact.path)
  end

  test "browser app contributes a valid workspace panel from cache artifacts" do
    assert {:ok, _artifact} =
             Cache.put("session-2", "extraction", "panel text",
               ext: ".txt",
               metadata: %{format: "text", preview: "panel text"}
             )

    assert [surface] = AllbertBrowser.App.workspace_panel_surfaces(%{user_id: "local"})
    assert %Surface{id: :browser_results_panel, app_id: :allbert_browser} = surface
    assert {:ok, _surface} = Surface.validate_surface(surface)

    assert surface.nodes
           |> hd()
           |> Map.get(:children)
           |> hd()
           |> Map.get(:props)
           |> Map.get(:body) =~ "session-2"
  end

  test "cache sweep job is created paused by default and can execute the sweep action" do
    assert {:ok, job} = Cache.ensure_sweep_job()
    assert job.status == "paused"
    assert job.target["action_name"] == "browser_sweep_cache"

    assert {:ok, _artifact} = Cache.put("session-3", "extraction", "old", ext: ".txt")
    assert {:ok, _run_result} = Runner.run_now(job)
    assert [%{status: "completed"}] = Jobs.list_runs(job)
  end

  defp restore_default_apps do
    _ = AppRegistry.register(AllbertAssist.App.CoreApp)
    _ = AppRegistry.register(StockSage.App)
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
