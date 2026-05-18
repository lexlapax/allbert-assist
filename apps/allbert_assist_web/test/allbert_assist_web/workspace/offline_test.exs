defmodule AllbertAssistWeb.Workspace.OfflineTest do
  use ExUnit.Case, async: true

  @app_js_path Path.expand("../../../assets/js/app.js", __DIR__)
  @service_worker_path Path.expand("../../../priv/static/workspace-sw.js", __DIR__)
  @offline_shell_path Path.expand("../../../priv/static/workspace-offline.html", __DIR__)

  test "workspace offline static files are exposed by Plug.Static" do
    assert "workspace-sw.js" in AllbertAssistWeb.static_paths()
    assert "workspace-offline.html" in AllbertAssistWeb.static_paths()
  end

  test "client registers workspace-scoped service worker and offline banner listeners" do
    app_js = File.read!(@app_js_path)

    assert app_js =~ "navigator.serviceWorker.register"
    assert app_js =~ "scope: shell.dataset.serviceWorkerScope || \"/agent\""
    assert app_js =~ "ALLBERT_WORKSPACE_CACHE_ASSETS"
    assert app_js =~ "window.addEventListener(\"offline\""
    assert app_js =~ "window.addEventListener(\"online\""
    assert app_js =~ "unregisterWorkspaceServiceWorker"
  end

  test "service worker caches shell assets without caching dynamic agent HTML" do
    service_worker = File.read!(@service_worker_path)

    assert service_worker =~ "const CACHE_NAME"
    assert service_worker =~ "/workspace-offline.html"
    assert service_worker =~ "request.mode === \"navigate\""
    assert service_worker =~ "url.pathname.startsWith(\"/agent\")"
    assert service_worker =~ "fetch(request).catch(() => caches.match(OFFLINE_SHELL_URL))"
    assert service_worker =~ "isShellAsset(url)"
    assert service_worker =~ "cache.put(request, copy)"
    refute service_worker =~ "\"/agent\","
  end

  test "offline fallback shell contains operator-facing offline banner" do
    offline_shell = File.read!(@offline_shell_path)

    assert offline_shell =~ ~s(id="workspace-offline-shell")
    assert offline_shell =~ ~s(data-offline-shell="true")
    assert offline_shell =~ "Working offline"
    assert offline_shell =~ "Runtime data will rehydrate"
  end
end
