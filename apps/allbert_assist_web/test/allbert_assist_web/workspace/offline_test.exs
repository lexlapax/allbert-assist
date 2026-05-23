defmodule AllbertAssistWeb.Workspace.OfflineTest do
  use ExUnit.Case, async: true

  @app_js_path Path.expand("../../../assets/js/app.js", __DIR__)
  @package_json_path Path.expand("../../../assets/package.json", __DIR__)
  @service_worker_path Path.expand("../../../priv/static/workspace-sw.js", __DIR__)
  @offline_shell_path Path.expand("../../../priv/static/workspace-offline.html", __DIR__)

  test "workspace offline static files are exposed by Plug.Static" do
    assert "workspace-sw.js" in AllbertAssistWeb.static_paths()
    assert "workspace-offline.html" in AllbertAssistWeb.static_paths()
  end

  test "client registers workspace-scoped service worker and offline banner listeners" do
    app_js = File.read!(@app_js_path)

    assert app_js =~ "navigator.serviceWorker.register"
    assert app_js =~ "scope: shell.dataset.serviceWorkerScope || \"/workspace\""
    assert app_js =~ "ALLBERT_WORKSPACE_CACHE_ASSETS"
    assert app_js =~ "window.addEventListener(\"offline\""
    assert app_js =~ "window.addEventListener(\"online\""
    assert app_js =~ "unregisterWorkspaceServiceWorker"
  end

  test "workspace tile editor hook uses Yjs, IndexedDB, and bounded LiveView pushes" do
    app_js = File.read!(@app_js_path)
    package_json = File.read!(@package_json_path)

    assert package_json =~ ~s("yjs")
    assert package_json =~ ~s("y-indexeddb")
    assert package_json =~ ~s("js-base64")

    assert app_js =~ ~s(import * as Y from "yjs")
    assert app_js =~ ~s(import {IndexeddbPersistence} from "y-indexeddb")
    assert app_js =~ "new Y.Doc()"
    assert app_js =~ "this.doc.getText(\"body\")"
    assert app_js =~ "new IndexeddbPersistence(this.docName, this.doc)"
    assert app_js =~ "provider.on(\"synced\""
    assert app_js =~ "this.doc.on(\"update\", this.handleUpdate)"
    assert app_js =~ "Y.mergeUpdates"
    assert app_js =~ "Y.encodeStateVector"
    assert app_js =~ "this.pushEvent(\"workspace_tile_editor_sync\""
    assert app_js =~ "estimateWorkspaceEditorBytes(payload) > this.quotaBytes"
    assert app_js =~ "this.markRecovery(\"quota_exceeded\")"
    assert app_js =~ "this.markRecovery(reply.reason || \"server_rejected\")"
    assert app_js =~ "this.doc?.destroy()"
    assert app_js =~ "FocusTrap"
    assert app_js =~ "WorkspaceSplitResizer"
    assert app_js =~ "WorkspaceTabs"
    assert app_js =~ "WorkspaceTileEditor"
  end

  test "offline recovery keeps rejected drafts addressable from the fallback shell" do
    app_js = File.read!(@app_js_path)

    assert app_js =~ "workspaceEditorManifestKey"
    assert app_js =~ "workspaceEditorCorruptManifestKey"
    assert app_js =~ "rawManifest"
    assert app_js =~ "workspace-offline-draft-recovery"
    assert app_js =~ "Recovery available:"
    assert app_js =~ "server_rejected"
    refute app_js =~ "indexedDB.deleteDatabase"
  end

  test "service worker caches shell assets without caching dynamic agent HTML" do
    service_worker = File.read!(@service_worker_path)

    assert service_worker =~ "const CACHE_NAME"
    assert service_worker =~ "/workspace-offline.html"
    assert service_worker =~ "request.mode === \"navigate\""
    assert service_worker =~ "url.pathname.startsWith(\"/workspace\")"
    assert service_worker =~ "fetch(request).catch(() => caches.match(OFFLINE_SHELL_URL))"
    assert service_worker =~ "isShellAsset(url)"
    assert service_worker =~ "cache.put(request, copy)"
    refute service_worker =~ "\"/workspace\","
  end

  test "offline fallback shell contains operator-facing offline banner" do
    offline_shell = File.read!(@offline_shell_path)

    assert offline_shell =~ ~s(id="workspace-offline-shell")
    assert offline_shell =~ ~s(data-offline-shell="true")
    assert offline_shell =~ ~s(id="workspace-offline-drafts")
    assert offline_shell =~ ~s(src="/assets/js/app.js")
    assert offline_shell =~ "Working offline"
    assert offline_shell =~ "Runtime data will rehydrate"
  end
end
