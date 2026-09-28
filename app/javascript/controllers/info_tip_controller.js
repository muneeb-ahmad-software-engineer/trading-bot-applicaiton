import { Controller } from "@hotwired/stimulus"

// Opens a setting's plain-language explanation on tap.
//
// Hover and keyboard focus already show it through CSS. This exists for touch,
// which has no hover, and for dismissing: Escape or a tap anywhere else closes
// it, so an open explanation never sits over the field the user wants next.
// Escape also hides one shown by hover or focus, until the pointer or focus
// leaves it — CSS alone cannot be dismissed.
export default class extends Controller {
  static targets = ["trigger"]

  connect() {
    this.closeOnOutside = (event) => {
      if (!this.element.contains(event.target)) this.close()
    }
    this.dismissOnEscape = (event) => {
      if (event.key !== "Escape") return
      this.close()
      this.element.dataset.dismissed = ""
    }
    this.undismiss = () => delete this.element.dataset.dismissed

    document.addEventListener("keydown", this.dismissOnEscape)
    this.element.addEventListener("mouseleave", this.undismiss)
    this.element.addEventListener("focusout", this.undismiss)
  }

  disconnect() {
    this.close()
    document.removeEventListener("keydown", this.dismissOnEscape)
  }

  toggle() {
    delete this.element.dataset.dismissed
    this.isOpen ? this.close() : this.open()
  }

  open() {
    this.element.dataset.open = ""
    this.triggerTarget.setAttribute("aria-expanded", "true")
    document.addEventListener("click", this.closeOnOutside)
  }

  close() {
    delete this.element.dataset.open
    this.triggerTarget.setAttribute("aria-expanded", "false")
    document.removeEventListener("click", this.closeOnOutside)
  }

  get isOpen() {
    return "open" in this.element.dataset
  }
}
