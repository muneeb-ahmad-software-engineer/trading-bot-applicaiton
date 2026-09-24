require "test_helper"

class DesignSystemTest < ActionDispatch::IntegrationTest
  test "style guide renders every component family" do
    get design_system_path

    assert_response :success

    # One assertion per component family from the brief's design system list.
    assert_select ".btn.btn-primary"
    assert_select ".card"
    assert_select ".input"
    assert_select ".select"
    assert_select ".checkbox"
    assert_select ".radio"
    assert_select ".badge"
    assert_select ".alert"
    assert_select ".navbar"
    assert_select "table.table"
    assert_select "dialog.modal"
    assert_select ".form-section"
    assert_select ".status .status-dot"
  end

  test "style guide is not indexable" do
    get design_system_path

    assert_select "meta[name=robots]" do |tags|
      assert_match(/noindex/, tags.first[:content])
    end
  end

  test "field partial wires label, hint and error to the control" do
    get design_system_path

    # The hint is referenced by aria-describedby rather than left as loose text.
    assert_select "#field_grid_spacing[aria-describedby=?]", "field_grid_spacing_hint"
    assert_select "#field_grid_spacing_hint"
    assert_select "label[for=?]", "field_grid_spacing"

    # An errored control is marked invalid and points at its message.
    assert_select "#field_max_positions[aria-invalid=true]"
    assert_select "#field_max_positions[aria-describedby=?]", "field_max_positions_error"
    assert_select "#field_max_positions_error", /greater than zero/
  end

  test "status indicators always carry a text label, never colour alone" do
    get design_system_path

    css_select(".status").each do |status|
      text = status.text.strip
      assert text.present?, "a .status indicator rendered with no text label"
    end

    # The dot itself is decorative and must be hidden from assistive tech.
    css_select(".status .status-dot").each do |dot|
      assert_equal "true", dot[:"aria-hidden"]
    end
  end

  test "destructive alerts are announced, informational ones are not" do
    get design_system_path

    assert_select ".alert-danger[role=alert]"
    assert_select ".alert-warning[role=alert]"
    assert_select ".alert-info[role=status]"
  end
end
