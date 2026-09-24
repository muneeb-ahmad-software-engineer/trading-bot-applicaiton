require "test_helper"

# The authenticated shell.
#
# Navigation is defined once in NavigationHelper and rendered by the sidebar,
# the mobile tab bar and the overflow sheet. These assert the three cannot drift
# apart, and that the current page is announced rather than only coloured.
class AppNavigationTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  VALID = {
    name: "XAUUSD grid", direction: "both", grid_spacing_points: 150, grid_levels: 5,
    initial_lot: 0.01, lot_mode: "fixed", max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  setup do
    @user = users(:verified)
    @strategy = @user.strategies.create!(VALID)
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
  end

  test "the sidebar replaces the marketing navbar once signed in" do
    get dashboard_path

    assert_select "aside.sidebar", count: 1
    assert_select "header.navbar", count: 0, message: "the marketing navbar must not appear inside the app"
  end

  test "the public landing page keeps the marketing navbar" do
    delete logout_path
    get root_path

    assert_select "header.navbar", count: 1
    assert_select "aside.sidebar", count: 0
  end

  test "every navigation destination is a real, reachable route" do
    get dashboard_path

    css_select("aside.sidebar a[href]").each do |link|
      next if link["href"].start_with?("#")

      get link["href"]
      assert_response :success, "sidebar links to #{link['href']}, which does not render"
    end
  end

  test "the current section is announced, not only coloured" do
    get strategies_path

    assert_select "aside.sidebar a[aria-current='page']", count: 1 do |links|
      assert_equal strategies_path, links.first["href"]
    end
  end

  test "a nested page still highlights its section" do
    get strategy_path(@strategy)

    # /strategies/3 must keep "Strategies" current, not fall back to nothing.
    assert_select "aside.sidebar a[aria-current='page'][href=?]", strategies_path
  end

  test "unread alerts are counted in the navigation" do
    3.times do |i|
      Notification.create!(user: @user, alert_type: "basket_closed", title: "t",
                           body: "b", dedup_key: "k#{i}", severity: "info")
    end

    get dashboard_path

    assert_select ".sidebar-badge", text: /3/
  end

  test "connection state is visible on every page, not only the dashboard" do
    [ strategies_path, trading_history_path, settings_path, profile_path ].each do |path|
      get path

      # "Is my terminal reporting?" must never be more than a glance away.
      assert_select "aside.sidebar [data-controller='connection-freshness']", count: 1,
        message: "#{path} does not show connection state"
    end
  end

  test "mobile navigation offers every destination the sidebar does" do
    get dashboard_path

    sidebar = css_select("aside.sidebar a[href]").map { _1["href"] }.reject { _1.start_with?("#") }
    mobile = css_select("nav.tab-bar a[href]").map { _1["href"] }

    assert_empty (sidebar - mobile),
      "these destinations are unreachable on a phone: #{(sidebar - mobile).join(', ')}"
  end

  test "the more sheet is a labelled dialog with a controlling trigger" do
    get dashboard_path

    assert_select "[data-sheet-target='trigger'][aria-expanded='false'][aria-haspopup='dialog']"
    assert_select "[data-sheet-target='panel'][role='dialog'][aria-modal='true'][aria-label]"
  end

  test "the risk warning appears on every authenticated page" do
    [ dashboard_path, strategies_path, settings_path ].each do |path|
      get path
      assert_match(/Risk warning/i, response.body, "#{path} omits the risk warning")
    end
  end
end
