import { Controller } from "@hotwired/stimulus"

// Copies a one-time secret — an API token — to the clipboard.
//
// With autoValue set, a copy is attempted as soon as the element appears, so a
// freshly issued token is already on the clipboard. That attempt is allowed to
// fail: most browsers only grant clipboard access during a user gesture, and a
// Turbo page render is not one. The button is therefore always present and is
// the real guarantee; the automatic copy is a convenience on top of it.
//
// Without JavaScript the token is still selectable text on the page.
export default class extends Controller {
  static targets = ["source", "button", "status"]
  static values = { auto: Boolean }

  connect() {
    if (this.autoValue) this.copy()
  }

  disconnect() {
    if (this.resetTimer) clearTimeout(this.resetTimer)
  }

  async copy(event) {
    if (event) event.preventDefault()

    const text = this.sourceTarget.textContent.trim()

    try {
      await navigator.clipboard.writeText(text)
      this.report("Copied to clipboard")
    } catch {
      // Clipboard denied (no user gesture, insecure origin, older browser).
      // Selecting the token is the next best thing: one keystroke copies it.
      this.select()
      if (event) this.report("Press ⌘C / Ctrl+C to copy")
    }
  }

  select() {
    const range = document.createRange()
    range.selectNodeContents(this.sourceTarget)
    const selection = window.getSelection()
    selection.removeAllRanges()
    selection.addRange(range)
  }

  report(message) {
    if (!this.hasStatusTarget) return

    this.statusTarget.textContent = message
    if (this.hasButtonTarget) this.buttonTarget.textContent = "Copied"

    if (this.resetTimer) clearTimeout(this.resetTimer)
    this.resetTimer = setTimeout(() => {
      this.statusTarget.textContent = ""
      if (this.hasButtonTarget) this.buttonTarget.textContent = "Copy"
    }, 4000)
  }
}
