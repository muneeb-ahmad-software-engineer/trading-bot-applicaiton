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
  static targets = ["category", "grid", "singlePosition", "reversal", "trailingRequired", "gridRequired"]

  connect() {
    this.apply()
  }

  apply() {
    const category = this.categoryTarget.value

    this.toggle(this.gridTargets, category === "grid")
    // Direction and the trailing stop belong to the single-position categories.
    // A grid's two order counts decide its sides, and its positions exit on the
    // basket target alone. Toggled before the reversal targets, which sit
    // inside the trailing section and must win for their own inputs.
    this.toggle(this.singlePositionTargets, category !== "grid")
    this.toggle(this.reversalTargets, category === "reversal")

    // A trailing or reversal strategy has no other exit, so its distance is
    // mandatory; a grid's only exit is the basket take profit.
    // Marking them required here matches the model, and keeps the browser from
    // letting an empty form reach the server for no reason.
    this.trailingRequiredTargets.forEach((field) => {
      field.required = category !== "grid"
    })
    this.gridRequiredTargets.forEach((field) => {
      field.required = category === "grid"
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
