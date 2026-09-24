import { Controller } from "@hotwired/stimulus"

// The "More" sheet on mobile navigation.
//
// Behaves like a dialog: Escape closes it, focus moves into it on open and
// returns to the trigger on close, and the page behind does not scroll.
export default class extends Controller {
  static targets = ["panel", "backdrop", "trigger"]

  connect() {
    this.close()
  }

  disconnect() {
    document.body.style.overflow = ""
  }

  open() {
    this.panelTarget.classList.remove("hidden")
    this.backdropTarget.classList.remove("hidden")
    this.triggerTarget.setAttribute("aria-expanded", "true")
    document.body.style.overflow = "hidden"

    const firstLink = this.panelTarget.querySelector("a, button")
    if (firstLink) firstLink.focus()
  }

  close() {
    if (!this.hasPanelTarget) return

    this.panelTarget.classList.add("hidden")
    this.backdropTarget.classList.add("hidden")
    this.triggerTarget.setAttribute("aria-expanded", "false")
    document.body.style.overflow = ""
  }

  closeOnEscape(event) {
    if (event.key === "Escape" && !this.panelTarget.classList.contains("hidden")) {
      this.close()
      this.triggerTarget.focus()
    }
  }
}
