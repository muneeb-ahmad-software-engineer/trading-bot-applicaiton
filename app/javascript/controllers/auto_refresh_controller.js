import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Reloads the page on an interval while it is showing a state that is about to
// change on its own — a terminal signing in to the broker, for instance.
//
// Without it, a strategy page opened the moment a strategy starts says
// "waiting for the terminal" forever, while the sidebar and the broker both
// show it trading. The element carrying this controller is only rendered in
// the waiting state, so once the terminal reports in, the refreshed page no
// longer has it and the refreshing stops by itself.
//
// Bounded by `until`, so a terminal that never connects does not keep
// reloading a tab left open overnight.
export default class extends Controller {
  static values = { interval: { type: Number, default: 10000 }, until: String }

  connect() {
    const deadline = Date.parse(this.untilValue)
    if (!Number.isNaN(deadline) && Date.now() > deadline) return

    this.timer = setTimeout(() => {
      Turbo.visit(window.location.href, { action: "replace" })
    }, this.intervalValue)
  }

  disconnect() {
    if (this.timer) clearTimeout(this.timer)
  }
}
