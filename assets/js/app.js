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
import {hooks as colocatedHooks} from "phoenix-colocated/chatterhead"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// A fresh id per page load, sent up as a connect param and kept in this user's
// presence meta. The goodbye below names it, so a beacon still in flight can
// only ever drop the presence of the page that sent it -- never the page the
// browser is navigating to, which has its own. The server only ever matches it
// within the current session, so it is a label, not a secret.
const pageId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  // A live client proves it's alive every 10s; the server drops a silent
  // connection after 25s (endpoint.ex). That timeout is only a backstop for a
  // client that vanishes without a word -- a leaving client says so below.
  heartbeatIntervalMs: 10_000,
  params: {_csrf_token: csrfToken, page_id: pageId},
  hooks: {...colocatedHooks},
})

// Say goodbye when the page goes away (tab close, navigation, clicking "Leave"),
// so everyone else's roster updates now rather than whenever the server notices
// the connection is gone.
//
// disconnect() alone is not enough, which is why the beacon leads. It closes the
// WebSocket via a setTimeout whenever the send buffer is non-empty, and timers
// stop running once a page is unloading; on the long-poll fallback it is an XHR
// the browser cancels outright; and a page frozen into the back/forward cache is
// never torn down, so there is no socket close for the OS to deliver either.
// sendBeacon is the one request a browser undertakes to deliver after the page
// is gone. See ChatterheadWeb.PresenceController.
window.addEventListener("pagehide", () => {
  navigator.sendBeacon("/away", new URLSearchParams({page_id: pageId, _csrf_token: csrfToken}))
  liveSocket.disconnect()
})

// pagehide also fires when a page is merely frozen into the back/forward cache,
// where it can be restored intact -- so reconnect, or Back would land on a page
// whose socket we just closed and never reopen it.
window.addEventListener("pageshow", event => {
  if (event.persisted) { liveSocket.connect() }
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

