import { Controller } from "@hotwired/stimulus"

// Collapses the desktop sidebar to an icon rail.
//
// The choice is remembered per browser, because someone who prefers the narrow
// rail wants it on every page, not just the one where they clicked.
export default class extends Controller {
  static targets = ["toggle"]
  static classes = ["collapsed"]

  connect() {
    this.collapsed = this.readPreference()
    this.apply()
  }

  toggle() {
    this.collapsed = !this.collapsed
    this.apply()
    this.writePreference()
  }

  apply() {
    this.element.classList.toggle("sidebar-collapsed", this.collapsed)

    if (this.hasToggleTarget) {
      this.toggleTarget.setAttribute("aria-expanded", String(!this.collapsed))
      this.toggleTarget.setAttribute(
        "aria-label",
        this.collapsed ? "Expand navigation" : "Collapse navigation"
      )
    }
  }

  readPreference() {
    // Storage can throw in a private window or when site data is blocked, and a
    // navigation preference is never worth breaking the page over.
    try {
      return window.localStorage.getItem("goldgrid:sidebar") === "collapsed"
    } catch {
      return false
    }
  }

  writePreference() {
    try {
      window.localStorage.setItem("goldgrid:sidebar", this.collapsed ? "collapsed" : "expanded")
    } catch {
      /* ignore */
    }
  }
}
