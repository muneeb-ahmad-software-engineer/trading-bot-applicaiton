require "test_helper"

class StrategiesTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  VALID = {
    name: "XAUUSD grid", direction: "both",
    grid_spacing_points: 150, grid_buy_orders: 5, grid_sell_orders: 5, basket_take_profit: 2,
    initial_lot: 0.01,
    max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  setup { login_as users(:verified) }

  def login_as(user)
    post login_path, params: { email_address: user.email_address, password: PASSWORD }
  end

  def create_strategy(user: users(:verified), **overrides)
    user.strategies.create!(VALID.merge(overrides))
  end

  test "creating a strategy saves a draft and trades nothing" do
    assert_difference "Strategy.count", 1 do
      post strategies_path, params: { strategy: VALID }
    end

    strategy = Strategy.last
    assert_predicate strategy, :draft?
    assert_redirected_to strategy
  end

  test "an invalid configuration is rejected with errors shown" do
    assert_no_difference "Strategy.count" do
      post strategies_path, params: { strategy: VALID.merge(grid_buy_orders: 50, max_positions: 5) }
    end

    assert_response :unprocessable_entity
    assert_match(/cannot exceed maximum positions/, response.body)
  end

  test "a strategy can be started and stopped" do
    strategy = create_strategy

    post start_strategy_path(strategy)
    assert_predicate strategy.reload, :running?

    post stop_strategy_path(strategy)
    assert_predicate strategy.reload, :stopped?
  end

  test "an emergency stop stops the strategy, flags it for the EA and is audited" do
    strategy = create_strategy
    strategy.start!

    post emergency_stop_strategy_path(strategy)

    assert_redirected_to strategy_path(strategy)
    strategy.reload
    assert_predicate strategy, :stopped?
    assert_predicate strategy, :emergency_stopped?
    assert Event.exists?(action: "strategy.emergency_stopped", subject: strategy)

    follow_redirect!
    assert_select ".alert", text: /Emergency stop active/
  end

  test "an unverified user cannot start a strategy" do
    strategy = create_strategy(user: users(:unverified))
    login_as users(:unverified)

    post start_strategy_path(strategy)

    assert_not strategy.reload.running?
    assert_match(/verify your email/i, flash[:alert])
  end

  test "a running strategy can be edited but not deleted" do
    strategy = create_strategy
    strategy.start!

    get edit_strategy_path(strategy)
    assert_response :success

    patch strategy_path(strategy), params: { strategy: { grid_buy_orders: 4, max_exposure_lots: 1.0 } }
    assert_redirected_to strategy
    assert_equal 4, strategy.reload.grid_buy_orders
    assert_predicate strategy, :running?

    patch strategy_path(strategy), params: { strategy: { category: "trailing" } }
    assert_response :unprocessable_entity
    assert_equal "grid", strategy.reload.category, "the strategy type must not change while running"

    assert_no_difference "Strategy.count" do
      delete strategy_path(strategy)
    end
  end

  test "a stopped strategy can be edited again" do
    strategy = create_strategy
    strategy.start!
    strategy.stop!

    patch strategy_path(strategy), params: { strategy: VALID.merge(grid_buy_orders: 4, max_exposure_lots: 1.0) }

    assert_equal 4, strategy.reload.grid_buy_orders
  end

  test "starting a second strategy for the same symbol is refused" do
    first = create_strategy(name: "first")
    first.start!
    second = create_strategy(name: "second")

    post start_strategy_path(second)

    assert_not second.reload.running?
    assert_match(/already running/i, flash[:alert])
  end

  test "one user cannot see, edit or control another user's strategy" do
    theirs = create_strategy(user: users(:unverified), name: "theirs")

    get strategy_path(theirs)
    assert_response :not_found

    patch strategy_path(theirs), params: { strategy: { name: "hijacked" } }
    assert_response :not_found

    post start_strategy_path(theirs)
    assert_response :not_found

    delete strategy_path(theirs)
    assert_response :not_found
    assert_equal "theirs", theirs.reload.name
  end

  test "the index only lists the current user's strategies" do
    create_strategy(name: "mine")
    create_strategy(user: users(:unverified), name: "not mine")

    get strategies_path

    assert_match "mine", response.body
    assert_no_match(/not mine/, response.body)
  end

  test "strategy pages never present fabricated trading figures" do
    strategy = create_strategy
    get strategy_path(strategy)

    assert_response :success
    # Nothing is executing this strategy, so the page must say so rather than
    # let empty tables read as a flat account.
    assert_match(/no terminal is connected/i, response.body)
    assert_match(/there are none to show/i, response.body)
  end

  # -------------------------------------------------------------- Trailing

  TRAILING = {
    name: "XAUUSD trailing", category: "trailing", direction: "both",
    initial_lot: 0.01, trailing_stop_points: 200,
    max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  test "creating a trailing strategy needs no grid fields" do
    # The form hides them for this category, so they arrive absent rather than
    # blank. Nothing downstream may require them.
    assert_difference "Strategy.count", 1 do
      post strategies_path, params: { strategy: TRAILING }
    end

    strategy = Strategy.last
    assert_predicate strategy, :category_trailing?
    assert_nil strategy.grid_buy_orders
    assert_nil strategy.grid_spacing_points
    assert_equal 200, strategy.trailing_stop_points
  end

  test "a trailing strategy with no distance is rejected with a reason the user can act on" do
    assert_no_difference "Strategy.count" do
      post strategies_path, params: { strategy: TRAILING.except(:trailing_stop_points) }
    end

    assert_response :unprocessable_entity
    assert_match(/trailing/i, response.body)
  end

  test "the strategy page shows the trailing distance in points and in dollars" do
    strategy = users(:verified).strategies.create!(TRAILING)

    get strategy_path(strategy)

    assert_response :success
    assert_match(/200 points/, response.body)
    assert_match(/\$2\.00/, response.body)
  end

  test "a grid with no trailing stop says so rather than showing a blank panel" do
    get strategy_path(create_strategy)

    assert_response :success
    assert_match(/Not configured/i, response.body)
  end

  test "switching a grid to trailing clears the grid it no longer has" do
    strategy = create_strategy

    patch strategy_path(strategy), params: {
      strategy: { category: "trailing", trailing_stop_points: 200,
                  grid_spacing_points: "", grid_buy_orders: "", grid_sell_orders: "" }
    }

    strategy.reload
    assert_predicate strategy, :category_trailing?
    assert_nil strategy.grid_buy_orders
  end
  # ------------------------------------------------ Setting explanations

  test "every field on the strategy form has a plain-language explanation" do
    get new_strategy_path

    assert_response :success
    # Every control the form submits, except the name-less symbol display.
    fields = css_select("[name^='strategy[']").map { |c| c["name"][/strategy\[(\w+)\]/, 1] }.uniq
    assert_not_empty fields

    fields.each do |field|
      assert_select "button.info-tip-trigger[aria-describedby='#{field}_info']", 1,
        "#{field} has no (i) explanation"
      assert_select "##{field}_info[role=tooltip]", text: I18n.t("strategy_help.#{field}")
    end
  end

  test "every setting on the strategy page has the same explanation as the form" do
    get strategy_path(users(:verified).strategies.create!(TRAILING))

    assert_response :success
    assert_select "#trailing_stop_points_info", text: I18n.t("strategy_help.trailing_stop_points")
    assert_select "#max_exposure_lots_info", text: I18n.t("strategy_help.max_exposure_lots")
  end
end
