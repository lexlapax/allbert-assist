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
})
window.addEventListener("phx:page-loading-stop", () => {
  bootstrapWorkspaceOffline()
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, FocusTrap},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
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
