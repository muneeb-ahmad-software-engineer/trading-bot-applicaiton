// Registers the service worker that backs the installed PWA shell.
//
// Registration is intentionally non-blocking and failure-tolerant: the app is a
// normal server-rendered Rails application first, and an installable PWA second.
// If the browser has no service worker support, or registration fails, every
// page still works over the network.
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/service-worker", { scope: "/" }).catch((error) => {
      console.warn("Service worker registration failed:", error)
    })
  })
}
