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

const setupAllbertTheme = () => {
  const storageKey = "allbert:theme"

  const setTheme = theme => {
    if (theme === "system") {
      localStorage.removeItem(storageKey)
      // v0.61 M9 — keep an explicit `system` marker so the CSS resolves it against the
      // OS prefers-color-scheme; removing the attribute would fall back to light.
      document.documentElement.setAttribute("data-theme", "system")
    } else {
      localStorage.setItem(storageKey, theme)
      document.documentElement.setAttribute("data-theme", theme)
    }
  }

  if (!document.documentElement.hasAttribute("data-theme")) {
    setTheme(localStorage.getItem(storageKey) || "system")
  }

  window.addEventListener("storage", event => {
    if (event.key === storageKey) setTheme(event.newValue || "system")
  })

  window.addEventListener("allbert:set-theme", event => {
    const target = event.target instanceof HTMLElement ? event.target : null
    setTheme(event.detail?.theme || target?.dataset?.allbertTheme || "system")
  })
}

setupAllbertTheme()

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
    this.previouslyFocused = document.activeElement instanceof HTMLElement ? document.activeElement : null

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
    if (this.previouslyFocused?.isConnected) {
      this.previouslyFocused.focus({preventScroll: true})
    }
  },
}

// v0.26a M29: Enter submits the composer form; Shift+Enter inserts a newline.
// IME composition (CJK / accents) is respected — only commit on Enter when
// `event.isComposing` is false. Modifier keys (Cmd/Ctrl/Alt) defer to default
// browser behavior so accessibility shortcuts keep working.
const ComposerEnter = {
  mounted() {
    this.handleKeydown = event => {
      if (event.key !== "Enter") return
      if (event.isComposing || event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return

      const formId = this.el.dataset.submitForm
      const form = formId ? document.getElementById(formId) : this.el.closest("form")
      if (!form) return

      event.preventDefault()

      if (typeof form.requestSubmit === "function") {
        form.requestSubmit()
      } else {
        form.dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}))
      }
    }

    this.el.addEventListener("keydown", this.handleKeydown)
  },
  destroyed() {
    this.el.removeEventListener("keydown", this.handleKeydown)
  },
}

// v0.26a M28: keep the chat timeline pinned to the latest message after
// LiveView re-renders, unless the operator has scrolled away from the bottom
// (in which case respect their position).
const ChatAutoScroll = {
  mounted() {
    this.stickyBottom = true
    this.handleScroll = () => {
      const distanceFromBottom = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
      this.stickyBottom = distanceFromBottom < 64
    }
    this.el.addEventListener("scroll", this.handleScroll, {passive: true})
    this.scrollToBottom()
  },
  updated() {
    if (this.stickyBottom) this.scrollToBottom()
  },
  destroyed() {
    this.el.removeEventListener("scroll", this.handleScroll)
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  },
}

const preferredVoiceMimeType = () => {
  const types = [
    "audio/webm;codecs=opus",
    "audio/webm",
    "audio/ogg;codecs=opus",
    "audio/ogg",
    "audio/mp4",
  ]

  if (typeof MediaRecorder === "undefined" || typeof MediaRecorder.isTypeSupported !== "function") {
    return ""
  }

  return types.find(type => MediaRecorder.isTypeSupported(type)) || ""
}

const voiceExtensionForMimeType = mimeType => {
  if (mimeType.includes("ogg")) return "ogg"
  if (mimeType.includes("mp4")) return "m4a"
  if (mimeType.includes("mpeg")) return "mp3"
  return "webm"
}

const WorkspaceVoiceCapture = {
  mounted() {
    this.input = this.el.querySelector("[data-voice-file-input]")
    this.startButton = this.el.querySelector("[data-voice-start]")
    this.stopButton = this.el.querySelector("[data-voice-stop]")
    this.submitButton = this.el.querySelector("#voice-capture-submit")
    this.status = this.el.querySelector("[data-voice-status]")
    this.maxDurationMs = Number.parseInt(this.el.dataset.maxDurationMs || "300000", 10)
    this.chunks = []
    this.stream = null
    this.recorder = null
    this.stopTimer = null

    this.handleStart = event => {
      event.preventDefault()
      this.startRecording()
    }

    this.handleStop = event => {
      event.preventDefault()
      this.stopRecording()
    }

    this.startButton?.addEventListener("click", this.handleStart)
    this.stopButton?.addEventListener("click", this.handleStop)
  },

  destroyed() {
    window.clearTimeout(this.stopTimer)
    this.stopTracks()
    this.startButton?.removeEventListener("click", this.handleStart)
    this.stopButton?.removeEventListener("click", this.handleStop)
  },

  async startRecording() {
    if (!this.input || typeof MediaRecorder === "undefined" || !navigator.mediaDevices?.getUserMedia) {
      this.setStatus("Unavailable")
      return
    }

    try {
      this.stream = await navigator.mediaDevices.getUserMedia({audio: true})
      const mimeType = preferredVoiceMimeType()
      this.chunks = []
      this.recorder = mimeType
        ? new MediaRecorder(this.stream, {mimeType})
        : new MediaRecorder(this.stream)

      this.recorder.addEventListener("dataavailable", event => {
        if (event.data && event.data.size > 0) this.chunks.push(event.data)
      })

      this.recorder.addEventListener("stop", () => this.finishRecording(mimeType))
      this.recorder.start()
      this.setRecording(true)
      this.setStatus("Recording")
      this.stopTimer = window.setTimeout(() => this.stopRecording(), this.maxDurationMs)
    } catch (_error) {
      this.stopTracks()
      this.setRecording(false)
      this.setStatus("Unavailable")
    }
  },

  stopRecording() {
    window.clearTimeout(this.stopTimer)

    if (this.recorder && this.recorder.state !== "inactive") {
      this.recorder.stop()
    } else {
      this.stopTracks()
      this.setRecording(false)
    }
  },

  finishRecording(mimeType) {
    this.stopTracks()
    this.setRecording(false)

    if (this.chunks.length === 0 || typeof DataTransfer === "undefined") {
      this.setStatus("No audio")
      return
    }

    const type = mimeType || this.chunks[0]?.type || "audio/webm"
    const extension = voiceExtensionForMimeType(type)
    const blob = new Blob(this.chunks, {type})
    const file = new File([blob], `voice-capture.${extension}`, {type})
    const transfer = new DataTransfer()
    transfer.items.add(file)
    this.input.files = transfer.files
    this.input.dispatchEvent(new Event("change", {bubbles: true}))
    this.submitButton?.removeAttribute("disabled")
    this.submitButton?.setAttribute("aria-disabled", "false")
    this.setStatus("Captured")

    window.setTimeout(() => {
      if (typeof this.el.requestSubmit === "function") {
        this.el.requestSubmit()
      } else {
        this.el.dispatchEvent(new Event("submit", {bubbles: true, cancelable: true}))
      }
    }, 0)
  },

  stopTracks() {
    this.stream?.getTracks()?.forEach(track => track.stop())
    this.stream = null
  },

  setRecording(recording) {
    if (this.startButton) {
      this.startButton.disabled = recording
      this.startButton.setAttribute("aria-disabled", recording ? "true" : "false")
    }

    if (this.stopButton) {
      this.stopButton.disabled = !recording
      this.stopButton.setAttribute("aria-disabled", recording ? "false" : "true")
    }
  },

  setStatus(text) {
    if (this.status) this.status.textContent = text
  },
}

// v0.26a M33: small copy-to-clipboard helper used for mono ids, paths, signal
// ids etc. The target text comes from `data-copy-value`; falls back to the
// element's text content. Emits a transient "Copied" affordance via aria-live.
const CopyToClipboard = {
  mounted() {
    this.handleClick = async event => {
      event.preventDefault()
      event.stopPropagation()
      const value = this.el.dataset.copyValue || this.el.textContent || ""
      try {
        await navigator.clipboard.writeText(value.trim())
        this.flashStatus("Copied")
      } catch (_error) {
        this.flashStatus("Copy failed")
      }
    }
    this.el.addEventListener("click", this.handleClick)
  },
  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
  },
  flashStatus(text) {
    const previous = this.el.getAttribute("data-copy-status") || ""
    this.el.setAttribute("data-copy-status", text)
    window.clearTimeout(this.statusTimer)
    this.statusTimer = window.setTimeout(() => {
      this.el.setAttribute("data-copy-status", previous)
    }, 1200)
  },
}

const workspaceSplitKey = "allbert.workspace.split_ratio.v1"

const clampWorkspaceSplit = value => {
  const numeric = Number.parseInt(value, 10)
  if (Number.isNaN(numeric)) return 55
  return Math.min(70, Math.max(35, numeric))
}

const WorkspaceSplitResizer = {
  mounted() {
    this.root = document.getElementById("workspace-node-workspace-root")
    this.grid = this.root?.querySelector(":scope > .workspace-root-grid")
    this.value = clampWorkspaceSplit(window.localStorage?.getItem(workspaceSplitKey) || this.el.dataset.defaultValue)

    this.applyValue(this.value)

    this.handlePointerMove = event => {
      if (!this.dragging || !this.grid) return

      const rect = this.grid.getBoundingClientRect()
      const next = ((event.clientX - rect.left) / rect.width) * 100
      this.applyValue(next)
    }

    this.handlePointerUp = () => {
      if (!this.dragging) return

      this.dragging = false
      this.el.releasePointerCapture?.(this.pointerId)
      this.persistValue()
    }

    this.handlePointerDown = event => {
      if (!this.grid || window.matchMedia("(max-width: 767.98px)").matches) return

      this.dragging = true
      this.pointerId = event.pointerId
      this.el.setPointerCapture?.(event.pointerId)
      this.handlePointerMove(event)
      event.preventDefault()
    }

    this.handleKeydown = event => {
      const step = event.shiftKey ? 5 : 2
      const keys = {
        ArrowLeft: -step,
        ArrowRight: step,
        Home: 35 - this.value,
        End: 70 - this.value,
      }

      if (!(event.key in keys)) return

      this.applyValue(this.value + keys[event.key])
      this.persistValue()
      event.preventDefault()
    }

    this.el.addEventListener("pointerdown", this.handlePointerDown)
    this.el.addEventListener("keydown", this.handleKeydown)
    window.addEventListener("pointermove", this.handlePointerMove)
    window.addEventListener("pointerup", this.handlePointerUp)
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.handlePointerDown)
    this.el.removeEventListener("keydown", this.handleKeydown)
    window.removeEventListener("pointermove", this.handlePointerMove)
    window.removeEventListener("pointerup", this.handlePointerUp)
  },

  applyValue(next) {
    this.value = clampWorkspaceSplit(next)
    this.root?.style.setProperty("--workspace-chat-ratio", `${this.value}%`)
    this.el.setAttribute("aria-valuenow", String(this.value))
  },

  persistValue() {
    try {
      window.localStorage?.setItem(workspaceSplitKey, String(this.value))
    } catch (_error) {
      // localStorage may be unavailable in hardened browser modes.
    }
  },
}

const WorkspaceTabs = {
  mounted() {
    this.tabs = () => Array.from(this.el.querySelectorAll("[role='tab']"))

    this.activate = tab => {
      for (const current of this.tabs()) {
        const selected = current === tab
        current.setAttribute("aria-selected", selected ? "true" : "false")
        current.setAttribute("tabindex", selected ? "0" : "-1")

        const panelId = current.getAttribute("aria-controls")
        const panel = panelId ? document.getElementById(panelId) : null
        if (panel) panel.hidden = !selected
      }

      tab.focus({preventScroll: true})
    }

    this.handleClick = event => {
      const tab = event.target.closest("[role='tab']")
      if (tab && this.el.contains(tab)) this.activate(tab)
    }

    this.handleKeydown = event => {
      const tabs = this.tabs()
      const index = tabs.indexOf(document.activeElement)
      if (index === -1) return

      const nextIndex = {
        ArrowRight: (index + 1) % tabs.length,
        ArrowDown: (index + 1) % tabs.length,
        ArrowLeft: (index - 1 + tabs.length) % tabs.length,
        ArrowUp: (index - 1 + tabs.length) % tabs.length,
        Home: 0,
        End: tabs.length - 1,
      }[event.key]

      if (nextIndex === undefined) return

      this.activate(tabs[nextIndex])
      event.preventDefault()
    }

    this.el.addEventListener("click", this.handleClick)
    this.el.addEventListener("keydown", this.handleKeydown)
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
    this.el.removeEventListener("keydown", this.handleKeydown)
  },
}

const workspaceEditorManifestKey = "allbert.workspace.tile_editors.v1"
const workspaceEditorCorruptManifestKey = "allbert.workspace.tile_editors.corrupt.v1"
const workspaceEditorOrigin = "allbert-workspace-editor"
const workspaceEditorBootstrapOrigin = "allbert-workspace-bootstrap"

const workspaceEditorMessages = {
  synced: "Saved locally",
  pending: "Saving locally",
  offline: "Saved locally; will sync when the connection returns.",
  pushed: "Local update sent to workspace.",
  conflict: "Conflict reconciled; review the tile banner.",
  rejected: "Local update kept; server sync rejected.",
  quota_exceeded: "Local draft is over the configured offline quota.",
  unavailable: "Offline editor unavailable in this browser.",
}

const readWorkspaceEditorManifest = () => {
  const rawManifest = window.localStorage?.getItem(workspaceEditorManifestKey) || "{}"

  try {
    return JSON.parse(rawManifest)
  } catch (error) {
    try {
      window.localStorage?.setItem(
        workspaceEditorCorruptManifestKey,
        JSON.stringify({
          preservedAt: new Date().toISOString(),
          reason: error.message,
          rawManifest,
        })
      )
    } catch (_storageError) {
      // localStorage may be unavailable in hardened browser modes.
    }

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

      const recovery = document.createElement("p")
      recovery.className = "workspace-offline-draft-recovery"
      recovery.hidden = !record.recovery
      recovery.textContent = record.recovery
        ? `Recovery available: ${record.recovery.reason || "local draft kept"}`
        : ""

      const body = document.createElement("pre")
      body.textContent = text || record.snapshot || ""

      article.append(title, recovery, body)
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
      recovery: null,
    }

    updateWorkspaceEditorManifest(record)
    this.provider?.set("snapshot", snapshot)
  },

  markRecovery(reason) {
    updateWorkspaceEditorManifest({
      docName: this.docName,
      tileId: this.tileId,
      threadId: this.threadId,
      userId: this.userId,
      kind: this.kind,
      title: this.el.closest("[data-workspace-component='tile']")?.querySelector("h2")?.textContent?.trim(),
      snapshot: this.ytext.toString(),
      recovery: {
        reason: reason || "server_rejected",
        retainedAt: new Date().toISOString(),
      },
    })
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
      this.markRecovery("quota_exceeded")
      setWorkspaceEditorState(this.el, "quota_exceeded")
      return
    }

    this.pushEvent("workspace_tile_editor_sync", payload, reply => {
      if (reply.current_revision_id) this.baseRevisionId = reply.current_revision_id

      if (reply.status === "received") {
        setWorkspaceEditorState(this.el, "pushed")
      } else if (reply.status === "conflict") {
        setWorkspaceEditorState(this.el, "conflict")
      } else {
        this.markRecovery(reply.reason || "server_rejected")
        setWorkspaceEditorState(this.el, "rejected")
      }
    })
  },
}

const workspaceOfflineMessages = {
  online: "Workspace cached for offline use.",
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
    new URL("/images/allbert-mark.svg", window.location.origin).href,
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
      scope: shell.dataset.serviceWorkerScope || "/workspace",
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
      hooks: {
        ...colocatedHooks,
        FocusTrap,
        WorkspaceSplitResizer,
        WorkspaceTabs,
        WorkspaceTileEditor,
        WorkspaceVoiceCapture,
        ComposerEnter,
        ChatAutoScroll,
        CopyToClipboard,
      },
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
