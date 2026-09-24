import { Controller } from "@hotwired/stimulus"

// Subscribes this browser to Web Push.
//
// Everything here degrades gracefully: push is an enhancement, and a browser
// that does not support it (or a user who declines) still gets email alerts.
export default class extends Controller {
  static values = { publicKey: String, url: String }
  static targets = ["button", "status"]

  connect() {
    if (!this.supported) {
      this.report("This browser does not support push notifications. Email alerts still work.")
      if (this.hasButtonTarget) this.buttonTarget.disabled = true
      return
    }

    if (Notification.permission === "denied") {
      this.report("Notifications are blocked in your browser settings. Email alerts still work.")
      if (this.hasButtonTarget) this.buttonTarget.disabled = true
    }
  }

  get supported() {
    return "serviceWorker" in navigator && "PushManager" in window && "Notification" in window
  }

  async subscribe(event) {
    event.preventDefault()
    if (!this.supported) return

    this.report("Requesting permission…")

    const permission = await Notification.requestPermission()
    if (permission !== "granted") {
      this.report("Permission was not granted. Email alerts still work.")
      return
    }

    try {
      const registration = await navigator.serviceWorker.ready
      const subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: this.urlBase64ToUint8Array(this.publicKeyValue)
      })

      const json = subscription.toJSON()
      const response = await fetch(this.urlValue, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content
        },
        body: JSON.stringify({
          endpoint: subscription.endpoint,
          p256dh_key: json.keys.p256dh,
          auth_key: json.keys.auth
        })
      })

      if (response.ok) {
        this.report("This device will now receive alerts.")
        if (this.hasButtonTarget) this.buttonTarget.disabled = true
      } else {
        this.report("Could not register this device. Please try again.")
      }
    } catch (error) {
      console.warn("Push subscription failed:", error)
      this.report("Could not register this device. Email alerts still work.")
    }
  }

  report(message) {
    if (this.hasStatusTarget) this.statusTarget.textContent = message
  }

  // VAPID keys are base64url; PushManager wants a Uint8Array.
  urlBase64ToUint8Array(base64String) {
    const padding = "=".repeat((4 - (base64String.length % 4)) % 4)
    const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/")
    const raw = window.atob(base64)
    return Uint8Array.from([...raw].map((char) => char.charCodeAt(0)))
  }
}
