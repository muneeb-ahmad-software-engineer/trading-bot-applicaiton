import { Controller } from "@hotwired/stimulus"

// Watches how long it has been since the terminal last reported.
//
// A live dashboard has a failure mode a static page does not: if updates stop
// arriving, the page keeps showing the last values and looks current. On a
// trading dashboard that is the most dangerous state possible — it says
// "connected" while nobody is watching the account.
//
// This runs entirely in the browser, so it still fires when the connection to
// the server is what broke.
export default class extends Controller {
  static targets = ["warning", "status", "age"]
  static values = { lastReport: String, staleAfter: Number }

  connect() {
    this.tick()
    this.timer = setInterval(() => this.tick(), 5000)
  }

  disconnect() {
    if (this.timer) clearInterval(this.timer)
  }

  tick() {
    if (!this.lastReportValue) return

    const reportedAt = Date.parse(this.lastReportValue)
    if (Number.isNaN(reportedAt)) return

    const secondsAgo = (Date.now() - reportedAt) / 1000
    const stale = secondsAgo > (this.staleAfterValue || 90)

    if (this.hasWarningTarget) this.warningTarget.classList.toggle("hidden", !stale)
    if (this.hasAgeTarget) this.ageTarget.textContent = this.describe(secondsAgo)

    if (stale && this.hasStatusTarget) {
      this.statusTarget.innerHTML =
        '<span class="status status-error"><span class="status-dot" aria-hidden="true"></span>' +
        "<span>Not reporting</span></span>"
    }
  }

  describe(seconds) {
    if (seconds < 60) return `${Math.max(0, Math.round(seconds))} seconds ago`
    if (seconds < 3600) return `${Math.round(seconds / 60)} minutes ago`
    return `${Math.round(seconds / 3600)} hours ago`
  }
}
