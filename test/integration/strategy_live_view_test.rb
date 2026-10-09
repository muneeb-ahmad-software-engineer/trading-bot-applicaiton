require "test_helper"

class StrategyLiveViewTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  VALID = {
    name: "XAUUSD grid", direction: "both",
    grid_spacing_points: 150, grid_buy_orders: 5, grid_sell_orders: 5, basket_take_profit: 2,
    initial_lot: 0.01,
    max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  setup do
    @user = users(:verified)
    @strategy = @user.strategies.create!(VALID)
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
  end

  def open_position(ticket:, volume: 0.01, profit: 10)
    @strategy.positions.create!(ticket:, direction: "buy", volume:, open_price: 2300,
                               current_price: 2310, profit:, swap: 0, commission: 0,
                               opened_at: 1.hour.ago)
  end

  test "a running strategy shows positions, orders and risk utilisation" do
    @strategy.start!
    open_position(ticket: "1")
    @strategy.orders.create!(ticket: "o1", order_type: "buy_limit", volume: 0.01,
                             price: 2290, placed_at: 1.hour.ago)

    get strategy_path(@strategy)

    assert_response :success
    assert_match(/Open positions/, response.body)
    assert_match(/Pending orders/, response.body)
    assert_match(/Risk utilisation/, response.body)
  end

  test "the robot state reported by the EA is shown in plain words, with any risk halt" do
    @strategy.start!
    @strategy.update_columns(max_daily_loss: 50)
    TerminalConnection.create!(
      user: @user, strategy: @strategy, api_token: ApiToken.issue(user: @user, name: "MT5"),
      symbol: "XAUUSD", last_report_at: Time.current,
      execution_state: "BUY_ACTIVE", execution_reason: "entry filled",
      reversal_level: 2316.40, daily_profit: -51.20, risk_halt: "Daily loss limit reached"
    )

    get strategy_path(@strategy)

    assert_select "h2", text: "Robot state"
    assert_match(/Holding a buy/, response.body)
    assert_match(/Sells\s+if price reaches/, response.body)
    assert_match(/2316.40/, response.body)
    assert_match(/Trading halted by a risk control/, response.body)
  end

  test "a grid's robot state shows its cycle, ladder, basket and pause" do
    @strategy.start!
    TerminalConnection.create!(
      user: @user, strategy: @strategy, api_token: ApiToken.issue(user: @user, name: "MT5"),
      symbol: "XAUUSD", last_report_at: Time.current,
      execution_state: "ARMED", execution_reason: "ladder complete — 8 resting, 2 filled, 0 skipped, capacity 10",
      cycle_number: 3, resting_orders: 8, filled_orders: 2, basket_profit: -0.84, pause_seconds_left: 0
    )

    get strategy_path(@strategy)

    assert_select "h2", text: "Robot state"
    assert_match(/Ladder in place/, response.body)
    assert_match(/Cycle/, response.body)
    assert_match(/2 filled/, response.body)
    assert_match(/8 resting/, response.body)
    assert_match(/Basket P\/L/, response.body)
    assert_match(/of 2\.00 target/, response.body)
    assert_no_match(/Next cycle in/, response.body, "the pause is only shown in COOLDOWN")
  end

  test "a grid in COOLDOWN shows the pause left before the next cycle" do
    @strategy.start!
    TerminalConnection.create!(
      user: @user, strategy: @strategy, api_token: ApiToken.issue(user: @user, name: "MT5"),
      symbol: "XAUUSD", last_report_at: Time.current,
      execution_state: "COOLDOWN", execution_reason: "confirmed flat; pausing 10 s",
      cycle_number: 4, resting_orders: 0, filled_orders: 0, basket_profit: 0, pause_seconds_left: 7
    )

    get strategy_path(@strategy)

    assert_match(/pausing before the next cycle/, response.body)
    assert_match(/Next cycle in/, response.body)
    assert_match(/7 seconds/, response.body)
  end

  test "risk meters report utilisation against the configured limits" do
    @strategy.start!
    # 5 of 10 positions.
    5.times { |i| open_position(ticket: "p#{i}") }

    get strategy_path(@strategy)

    assert_select "[role=meter]" do |meters|
      values = meters.map { _1["aria-valuenow"].to_f }
      assert_includes values, 50.0, "5 of 10 positions should read 50%"
    end
  end

  test "a meter always states its status in words" do
    @strategy.start!
    9.times { |i| open_position(ticket: "p#{i}") }

    get strategy_path(@strategy)

    # 90% of the position limit is "At limit" — and must say so, not merely
    # turn red, because red/green is not a safe sole encoding.
    assert_match(/At limit/, response.body)
    assert_select "[role=meter][aria-label*='At limit']"
  end

  test "P/L is signed so it does not depend on colour" do
    @strategy.start!
    open_position(ticket: "1", profit: 42)

    get strategy_path(@strategy)

    assert_match(/\+42\.00/, response.body)
    assert_select ".sr-only", text: "profit"
  end

  test "no positions reported reads as no data, not as zero" do
    @strategy.start!

    get strategy_path(@strategy)

    assert_match(/No positions reported/, response.body)
  end

  test "a draft strategy with no data shows configuration only" do
    get strategy_path(@strategy)

    assert_response :success
    assert_no_match(/Risk utilisation/, response.body)
  end

  test "closed positions link through to filtered history" do
    @strategy.positions.create!(ticket: "c1", direction: "buy", volume: 0.01,
                               open_price: 2300, close_price: 2310, profit: 10,
                               opened_at: 2.hours.ago, closed_at: 1.hour.ago)

    get strategy_path(@strategy)

    assert_select "a[href=?]", trading_history_path(strategy_id: @strategy.id)
  end

  # --------------------------------------------------- Self-hosted terminals

  def connect_terminal(strategy: @strategy, last_report_at: Time.current)
    TerminalConnection.create!(
      user: @user, strategy:, api_token: ApiToken.issue(user: @user, name: "t#{rand(10_000)}"),
      symbol: "XAUUSD", broker: "MetaQuotes Ltd.", last_report_at:
    )
  end

  # The bug this pins: a user running MetaTrader themselves with an API token
  # has no managed instance and no stored broker credentials. Judging by those
  # alone declared a terminal that was reporting every ten seconds to be
  # absent, on the page whose whole job is to answer "is anything running
  # this?" — while the sidebar said it was connected.
  test "a terminal the user runs themselves counts as connected" do
    @strategy.start!
    connect_terminal

    get strategy_path(@strategy)

    assert_response :success
    assert_match(/Your terminal is connected/i, response.body)
    assert_match(/MetaQuotes Ltd\./, response.body)
    assert_no_match(/No terminal is connected/i, response.body)
  end

  test "a terminal that has gone quiet is not the same as one that never connected" do
    # Different problem, different fix. "Never connected" sends the user to set
    # up a token; "stopped reporting" sends them to check MetaTrader is open.
    @strategy.start!
    connect_terminal(last_report_at: 1.hour.ago)

    get strategy_path(@strategy)

    assert_response :success
    assert_match(/stopped reporting/i, response.body)
    assert_no_match(/No terminal is connected/i, response.body)
  end

  test "a terminal reporting for another strategy does not vouch for this one" do
    other = @user.strategies.create!(VALID.merge(name: "Other"))
    @strategy.start!
    connect_terminal(strategy: other)

    get strategy_path(@strategy)

    assert_response :success
    assert_match(/No terminal is connected/i, response.body)
  end
end
