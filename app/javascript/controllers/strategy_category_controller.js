import { Controller } from "@hotwired/stimulus"

// Shows only the sections that belong to the selected strategy category.
//
// This hides fields; it does not decide anything. Every rule this mirrors is
// enforced again in Strategy, because a form control is not a validation and
// the API accepts configurations that never passed through this page.
//
// Without JavaScript every section stays visible and the form still submits
// correctly — the irrelevant fields are simply ignored for that category.
export default class extends Controller {
  static targets = ["category", "grid", "trailingRequired"]

  connect() {
    this.apply()
  }

  apply() {
    const category = this.categoryTarget.value

    this.toggle(this.gridTargets, category === "grid")

    // A trailing strategy has no other exit, so its distance is mandatory.
    // Marking it required here matches the model, and keeps the browser from
    // letting an empty form reach the server for no reason.
    this.trailingRequiredTargets.forEach((field) => {
      field.required = category === "trailing"
    })
  }

  toggle(elements, visible) {
    elements.forEach((element) => {
      element.hidden = !visible
      // Hidden fields must not be validated by the browser, or an invisible
      // empty input blocks submission with a message nobody can see.
      element.querySelectorAll("input, select").forEach((field) => {
        field.disabled = !visible
      })
    })
  }
}
