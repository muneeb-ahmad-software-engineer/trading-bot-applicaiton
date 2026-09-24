require "test_helper"

# The route foundation from the product brief.
#
# These were public placeholders before authentication existed. They are now
# real authenticated surfaces, so this asserts that each route resolves, is
# reachable once signed in, and is never exposed to search engines.
class RouteSkeletonTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  ROUTES = {
    "dashboard" => "/dashboard",
    "strategies" => "/strategies",
    "new strategy" => "/strategies/new",
    "settings" => "/settings",
    "profile" => "/profile",
    "api tokens" => "/settings/api-tokens"
  }.freeze

  def login
    post login_path, params: { email_address: "verified@example.com", password: PASSWORD }
  end

  test "an individual strategy route resolves for a strategy the user owns" do
    login
    strategy = users(:verified).strategies.create!(
      name: "XAUUSD grid", grid_spacing_points: 150, grid_levels: 5,
      initial_lot: 0.01, max_positions: 10, max_exposure_lots: 0.5
    )

    get "/strategies/#{strategy.id}"

    assert_response :success
    assert_select "meta[name=robots][content=?]", "noindex"
  end

  ROUTES.each do |name, path|
    test "#{name} route resolves and is reachable when signed in" do
      login
      get path

      assert_response :success
      assert_select "meta[name=robots][content=?]", "noindex"
    end
  end

  test "public marketing routes remain reachable and indexable" do
    get root_path

    assert_response :success
    assert_select "meta[name=robots]", count: 0, message: "the landing page must stay indexable"
  end

  test "signup and login are reachable but not indexed" do
    [ signup_path, login_path ].each do |path|
      get path

      assert_response :success
      assert_select "meta[name=robots][content=?]", "noindex"
    end
  end
end
