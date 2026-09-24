// Service worker for the installed PWA shell.
//
// Deliberate scope: this worker makes the *application shell* resilient — icons,
// compiled assets and an offline notice. It never caches trading data. Anything
// under /api/ always goes to the network so a stale price, position or basket
// P/L can never be shown as if it were current. Trading requires a live
// connection, and the offline page says so.
//
// Bump CACHE_VERSION whenever the precached shell changes.
const CACHE_VERSION = "v1"
const SHELL_CACHE = `shell-${CACHE_VERSION}`
const ASSET_CACHE = `assets-${CACHE_VERSION}`
const OFFLINE_URL = "/offline"

// Only these navigations may be cached. Everything else — the dashboard,
// settings, history, alerts — renders account data, and a copy of that sitting
// in Cache Storage would outlive the session and be readable by whoever holds
// the device next.
const CACHEABLE_PAGES = ["/", "/login", "/signup", "/passwords/new", OFFLINE_URL]

const SHELL_URLS = [
  OFFLINE_URL,
  "/icon.svg",
  "/icons/icon-192.png",
  "/icons/icon-512.png"
]

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(SHELL_CACHE)
      .then((cache) => cache.addAll(SHELL_URLS))
      .then(() => self.skipWaiting())
  )
})

self.addEventListener("activate", (event) => {
  const keep = [SHELL_CACHE, ASSET_CACHE]

  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => !keep.includes(key)).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  )
})

self.addEventListener("fetch", (event) => {
  const request = event.request

  // Only GET requests are cacheable, and only from our own origin.
  if (request.method !== "GET") return
  const url = new URL(request.url)
  if (url.origin !== self.location.origin) return

  // Never serve API or health traffic from a cache — it must be live or fail.
  if (url.pathname.startsWith("/api/") || url.pathname === "/up") return

  if (request.mode === "navigate") {
    event.respondWith(networkFirstPage(request, CACHEABLE_PAGES.includes(url.pathname)))
  } else if (url.pathname.startsWith("/assets/") || url.pathname.startsWith("/icons/")) {
    event.respondWith(cacheFirstAsset(request))
  }
})

// Pages: always try the network so the user sees current state; fall back to a
// previously visited copy, and finally to the offline notice.
async function networkFirstPage(request, cacheable) {
  try {
    const response = await fetch(request)

    // Two independent conditions, deliberately. The allowlist is the primary
    // guard; honouring no-store means a page that becomes account-specific
    // later is never cached even if someone forgets to update the list.
    const storable =
      cacheable &&
      response.ok &&
      !(response.headers.get("Cache-Control") || "").includes("no-store")

    if (storable) {
      const cache = await caches.open(SHELL_CACHE)
      cache.put(request, response.clone())
    }
    return response
  } catch (error) {
    const cached = await caches.match(request)
    if (cached) return cached

    const offline = await caches.match(OFFLINE_URL)
    if (offline) return offline

    return new Response("You are offline.", {
      status: 503,
      headers: { "Content-Type": "text/plain" }
    })
  }
}

// Digest-stamped assets are immutable, so serving them from cache is safe.
async function cacheFirstAsset(request) {
  const cached = await caches.match(request)
  if (cached) return cached

  const response = await fetch(request)
  if (response.ok) {
    const cache = await caches.open(ASSET_CACHE)
    cache.put(request, response.clone())
  }
  return response
}

// ---------------------------------------------------------------- Web Push
//
// Alert content is carried in the push payload rather than fetched on receipt:
// a device receiving a push may have no working connection to this platform,
// and "your terminal stopped reporting" is exactly the alert most likely to
// arrive when connectivity is poor.

self.addEventListener("push", (event) => {
  if (!event.data) return

  let payload
  try {
    payload = event.data.json()
  } catch (error) {
    payload = { title: "GoldGrid", body: event.data.text() }
  }

  const critical = payload.severity === "critical"

  event.waitUntil(
    self.registration.showNotification(payload.title || "GoldGrid", {
      body: payload.body || "",
      icon: "/icons/icon-192.png",
      badge: "/icons/icon-192.png",
      // Same tag replaces an existing banner for the same situation rather
      // than stacking duplicates.
      tag: payload.tag || "goldgrid",
      renotify: critical,
      // A critical alert stays on screen until acknowledged. Trading alerts
      // should not disappear while the user is away from the device.
      requireInteraction: critical,
      data: { url: payload.url || "/dashboard", notificationId: payload.notification_id }
    })
  )
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()
  const target = (event.notification.data && event.notification.data.url) || "/dashboard"

  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((windowClients) => {
      // Focus an existing tab rather than opening another copy of the app.
      for (const client of windowClients) {
        if (new URL(client.url).pathname === target && "focus" in client) {
          return client.focus()
        }
      }
      if (clients.openWindow) return clients.openWindow(target)
    })
  )
})
