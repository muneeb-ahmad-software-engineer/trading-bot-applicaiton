import { Controller } from "@hotwired/stimulus"

// Toggles the mobile navigation panel.
//
// Visibility is driven by the `hidden` attribute rather than a CSS class so the
// menu is genuinely removed from the accessibility tree when closed, and
// aria-expanded is kept in step with it on every state change.
export default class extends Controller {
  static targets = ["menu", "button"]

  connect() {
    this.close()
  }

  toggle() {
    this.menuTarget.hidden ? this.open() : this.close()
  }

  open() {
    this.menuTarget.hidden = false
    this.buttonTarget.setAttribute("aria-expanded", "true")
    this.buttonTarget.setAttribute("aria-label", "Close menu")
  }

  close() {
    this.menuTarget.hidden = true
    this.buttonTarget.setAttribute("aria-expanded", "false")
    this.buttonTarget.setAttribute("aria-label", "Open menu")
  }

  // Close when focus or a click leaves the header, so the panel cannot be left
  // open behind the rest of the page.
  clickOutside(event) {
    if (!this.element.contains(event.target)) this.close()
  }
}
