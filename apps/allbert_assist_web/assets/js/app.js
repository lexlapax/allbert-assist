// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/allbert_assist_web"
import * as Y from "yjs"
import {IndexeddbPersistence} from "y-indexeddb"
import {fromUint8Array} from "js-base64"
import topbar from "../vendor/topbar"

const focusableSelector = [
  "a[href]",
  "button:not([disabled])",
  "textarea:not([disabled])",
  "input:not([disabled]):not([type='hidden'])",
  "select:not([disabled])",
  "[tabindex]:not([tabindex='-1'])",
].join(",")

const focusableElements = root => {
  return Array.from(root.querySelectorAll(focusableSelector)).filter(element => {
    return element.getAttribute("aria-hidden") !== "true" && element.offsetParent !== null
  })
}

const FocusTrap = {
  mounted() {
    if (!this.el.hasAttribute("tabindex")) {
      this.el.setAttribute("tabindex", "-1")
    }

    this.handleKeydown = event => {
      if (event.key !== "Tab") return

      const elements = focusableElements(this.el)

      if (elements.length === 0) {
        event.preventDefault()
        this.el.focus({preventScroll: true})
        return
      }

      const first = elements[0]
      const last = elements[elements.length - 1]

      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }

    this.el.addEventListener("keydown", this.handleKeydown)

    requestAnimationFrame(() => {
      const [first] = focusableElements(this.el)
      ;(first || this.el).focus({preventScroll: true})
    })
  },
  destroyed() {
    this.el.removeEventListener("keydown", this.handleKeydown)
  },
}

const workspaceEditorManifestKey = "allbert.workspace.tile_editors.v1"
const workspaceEditorOrigin = "allbert-workspace-editor"
const workspaceEditorBootstrapOrigin = "allbert-workspace-bootstrap"

const workspaceEditorMessages = {
  synced: "Saved locally",
  pending: "Saving locally",
  offline: "Saved locally; will sync when the connection returns.",
  pushed: "Local update sent to workspace.",
  rejected: "Local update kept; server sync rejected.",
  quota_exceeded: "Local draft is over the configured offline quota.",
  unavailable: "Offline editor unavailable in this browser.",
}

const readWorkspaceEditorManifest = () => {
  try {
    return JSON.parse(window.localStorage?.getItem(workspaceEditorManifestKey) || "{}")
  } catch (_error) {
    return {}
  }
}

const writeWorkspaceEditorManifest = manifest => {
  try {
    window.localStorage?.setItem(workspaceEditorManifestKey, JSON.stringify(manifest))
  } catch (_error) {
    // localStorage may be unavailable in hardened browser modes.
  }
}

const updateWorkspaceEditorManifest = record => {
  const manifest = readWorkspaceEditorManifest()
  manifest[record.docName] = {...manifest[record.docName], ...record, updatedAt: new Date().toISOString()}
  writeWorkspaceEditorManifest(manifest)
}

const workspaceEditorDocName = ({userId, threadId, tileId}) => {
  return ["allbert", "workspace", "tile", userId, threadId, tileId]
    .map(value => encodeURIComponent(value || "unknown"))
    .join(":")
}

const estimateWorkspaceEditorBytes = ({update, stateVector, snapshot}) => {
  const binaryBytes = Math.ceil(((update || "").length + (stateVector || "").length) * 0.75)
  return binaryBytes + new TextEncoder().encode(snapshot || "").length
}

const setWorkspaceEditorState = (root, state) => {
  root.dataset.syncState = state
  const status = root.querySelector("[data-workspace-editor-status]")
  if (status) status.textContent = workspaceEditorMessages[state] || workspaceEditorMessages.synced
}

const renderWorkspaceOfflineDrafts = async () => {
  const container = document.getElementById("workspace-offline-drafts")
  if (!container || container.dataset.loaded === "true") return

  container.dataset.loaded = "true"
  const manifest = Object.values(readWorkspaceEditorManifest()).sort((left, right) => {
    return (right.updatedAt || "").localeCompare(left.updatedAt || "")
  })

  if (manifest.length === 0) {
    container.textContent = "No local text or markdown drafts are cached on this device."
    return
  }

  container.textContent = ""

  await Promise.all(
    manifest.map(async record => {
      const doc = new Y.Doc()
      const provider = new IndexeddbPersistence(record.docName, doc)

      await provider.whenSynced
      const text = doc.getText("body").toString()

      const article = document.createElement("article")
      article.className = "workspace-offline-draft"
      article.dataset.tileId = record.tileId

      const title = document.createElement("h2")
      title.textContent = record.title || `${record.kind || "text"} tile`

      const body = document.createElement("pre")
      body.textContent = text || record.snapshot || ""

      article.append(title, body)
      container.append(article)

      doc.destroy()
    })
  )
}

const WorkspaceTileEditor = {
  mounted() {
    this.input = this.el.querySelector("[data-workspace-editor-input]")

    if (!this.input || !("indexedDB" in window)) {
      setWorkspaceEditorState(this.el, "unavailable")
      return
    }

    this.tileId = this.el.dataset.tileId
    this.threadId = this.el.dataset.threadId
    this.userId = this.el.dataset.userId
    this.kind = this.el.dataset.kind || "text"
    this.baseRevisionId = this.el.dataset.baseRevisionId || null
    this.quotaBytes = parseInt(this.el.dataset.quotaBytes || "33554432", 10)
    this.docName = workspaceEditorDocName({
      userId: this.userId,
      threadId: this.threadId,
      tileId: this.tileId,
    })
    this.pendingUpdates = []
    this.ready = false
    this.pushTimer = null
    this.doc = new Y.Doc()
    this.ytext = this.doc.getText("body")
    this.provider = new IndexeddbPersistence(this.docName, this.doc)

    this.handleInput = () => {
      const next = this.input.value
      this.doc.transact(() => {
        this.ytext.delete(0, this.ytext.length)
        this.ytext.insert(0, next)
      }, workspaceEditorOrigin)
      this.persistSnapshot(next)
    }

    this.handleOnline = () => {
      setWorkspaceEditorState(this.el, "pending")
      this.pushSnapshot("offline_reconnect")
    }

    this.handleUpdate = (update, origin) => {
      if (!this.ready || origin !== workspaceEditorOrigin) return

      this.pendingUpdates.push(update)
      setWorkspaceEditorState(this.el, navigator.onLine ? "pending" : "offline")

      if (navigator.onLine) {
        this.schedulePush()
      }
    }

    this.doc.on("update", this.handleUpdate)
    this.input.addEventListener("input", this.handleInput)
    window.addEventListener("online", this.handleOnline)

    this.provider.on("synced", () => {
      if (this.ytext.length === 0 && this.input.value !== "") {
        this.doc.transact(() => {
          this.ytext.insert(0, this.input.value)
        }, workspaceEditorBootstrapOrigin)
      } else {
        this.input.value = this.ytext.toString()
      }

      this.ready = true
      this.persistSnapshot(this.input.value)
      setWorkspaceEditorState(this.el, navigator.onLine ? "synced" : "offline")
    })
  },

  destroyed() {
    clearTimeout(this.pushTimer)
    this.input?.removeEventListener("input", this.handleInput)
    window.removeEventListener("online", this.handleOnline)

    if (this.doc && this.handleUpdate) {
      this.doc.off("update", this.handleUpdate)
    }

    this.doc?.destroy()
  },

  persistSnapshot(snapshot) {
    const record = {
      docName: this.docName,
      tileId: this.tileId,
      threadId: this.threadId,
      userId: this.userId,
      kind: this.kind,
      title: this.el.closest("[data-workspace-component='tile']")?.querySelector("h2")?.textContent?.trim(),
      snapshot,
    }

    updateWorkspaceEditorManifest(record)
    this.provider?.set("snapshot", snapshot)
  },

  schedulePush() {
    clearTimeout(this.pushTimer)
    this.pushTimer = setTimeout(() => this.pushPendingUpdates(), 250)
  },

  pushPendingUpdates() {
    if (this.pendingUpdates.length === 0) return

    const update = Y.mergeUpdates(this.pendingUpdates)
    this.pendingUpdates = []
    this.pushUpdate(update, "browser")
  },

  pushSnapshot(origin) {
    if (!this.doc) return

    this.pushUpdate(Y.encodeStateAsUpdate(this.doc), origin)
  },

  pushUpdate(update, origin) {
    const payload = {
      tile_id: this.tileId,
      thread_id: this.threadId,
      user_id: this.userId,
      kind: this.kind,
      base_revision_id: this.baseRevisionId,
      origin,
      update: fromUint8Array(update),
      state_vector: fromUint8Array(Y.encodeStateVector(this.doc)),
      snapshot: this.ytext.toString(),
    }

    if (estimateWorkspaceEditorBytes(payload) > this.quotaBytes) {
      setWorkspaceEditorState(this.el, "quota_exceeded")
      return
    }

    this.pushEvent("workspace_tile_editor_sync", payload, reply => {
      setWorkspaceEditorState(this.el, reply.status === "received" ? "pushed" : "rejected")
    })
  },
}

const workspaceOfflineMessages = {
  online: "Workspace shell cached for offline use.",
  offline: "Working offline — your shell is cached and changes will sync when you reconnect.",
  unavailable: "Offline mode unavailable in this environment.",
  disabled: "Offline mode disabled.",
}

const setWorkspaceOfflineBanner = state => {
  const banner = document.getElementById("workspace-offline-banner")
  if (!banner) return

  banner.dataset.state = state
  banner.textContent = workspaceOfflineMessages[state] || workspaceOfflineMessages.unavailable
  banner.hidden = state === "online"
}

const workspaceShellAssets = shell => {
  const assets = [
    shell.dataset.offlineShellUrl,
    document.querySelector("link[rel='stylesheet']")?.href,
    document.querySelector("script[src*='/assets/js/app.js']")?.src,
    new URL("/images/logo.svg", window.location.origin).href,
    new URL("/favicon.ico", window.location.origin).href,
  ]

  return assets.filter(Boolean)
}

const unregisterWorkspaceServiceWorker = async serviceWorkerUrl => {
  const registrations = await navigator.serviceWorker.getRegistrations()

  await Promise.all(
    registrations
      .filter(registration => registration.active?.scriptURL.includes(serviceWorkerUrl))
      .map(registration => registration.unregister())
  )
}

const postWorkspaceShellAssets = (registration, assets) => {
  const worker = registration.active || registration.waiting || registration.installing
  if (!worker) return

  worker.postMessage({
    type: "ALLBERT_WORKSPACE_CACHE_ASSETS",
    assets,
  })
}

const bootstrapWorkspaceOffline = async () => {
  const shell = document.getElementById("workspace-shell")
  if (!shell || shell.dataset.offlineBootstrapped === "true") return

  shell.dataset.offlineBootstrapped = "true"

  if (!("serviceWorker" in navigator)) {
    setWorkspaceOfflineBanner("unavailable")
    return
  }

  const serviceWorkerUrl = shell.dataset.serviceWorkerUrl || "/workspace-sw.js"

  if (shell.dataset.offlineEnabled !== "true") {
    await unregisterWorkspaceServiceWorker(serviceWorkerUrl)
    setWorkspaceOfflineBanner("disabled")
    return
  }

  window.addEventListener("offline", () => setWorkspaceOfflineBanner("offline"))
  window.addEventListener("online", () => setWorkspaceOfflineBanner("online"))

  try {
    const registration = await navigator.serviceWorker.register(serviceWorkerUrl, {
      scope: shell.dataset.serviceWorkerScope || "/agent",
    })

    postWorkspaceShellAssets(registration, workspaceShellAssets(shell))
    setWorkspaceOfflineBanner(navigator.onLine ? "online" : "offline")
  } catch (_error) {
    setWorkspaceOfflineBanner("unavailable")
  }
}

window.addEventListener("DOMContentLoaded", () => {
  bootstrapWorkspaceOffline()
  renderWorkspaceOfflineDrafts()
})
window.addEventListener("phx:page-loading-stop", () => {
  bootstrapWorkspaceOffline()
})

const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content")
const liveSocket = csrfToken
  ? new LiveSocket("/live", Socket, {
      longPollFallbackMs: 2500,
      params: {_csrf_token: csrfToken},
      hooks: {...colocatedHooks, FocusTrap, WorkspaceTileEditor},
    })
  : null

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket?.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
if (liveSocket) window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (liveSocket && process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
