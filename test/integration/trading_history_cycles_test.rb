require "test_helper"

class TradingHistoryCyclesTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  VALID = {
    name: "XAUUSD grid", direction: "both", grid_spacing_points: 120, grid_buy_orders: 25, grid_sell_orders: 25,
    basket_take_profit: 0.7, initial_lot: 0.01, max_positions: 50, max_exposure_lots: 0.5
  }.freeze

  setup do
    @user = users(:verified)
    @strategy = @user.strategies.create!(VALID)
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
  end

  def close_position(ticket:, profit:, opened_at:, closed_at:, strategy: @strategy)
    strategy.positions.create!(ticket:, direction: "buy", volume: 0.01, open_price: 4150, close_price: 4151,
                               profit:, swap: 0, commission: 0, opened_at:, closed_at:)
  end

  def snapshot(at:, balance:, equity:, margin: nil, user: @user)
    AccountSnapshot.create!(user:, balance:, equity:, margin:, recorded_at: at)
  end

  test "a cycle opens with its positions, the account at its start and its end, and its result" do
    base = Time.utc(2026, 10, 13, 15, 28, 53)
    close_position(ticket: "a", profit: 2.09, opened_at: base - 1.hour, closed_at: base)
    close_position(ticket: "b", profit: -11.55, opened_at: base - 50.minutes, closed_at: base + 3.seconds)
    close_position(ticket: "c", profit: 5.99, opened_at: base - 40.minutes, closed_at: base + 4.seconds)
    snapshot(at: base - 1.hour - 30.seconds, balance: 1000, equity: 996, margin: 90)
    snapshot(at: base + 10.seconds, balance: 997.44, equity: 997.44)

    get trading_history_cycle_path(@strategy.positions.order(:closed_at).first.id)

    assert_response :success
    assert_match(/Closed cycle/, response.body)
    assert_match(/\$1,000\.00/, response.body, "balance at the start of the cycle")
    assert_match(/\$997\.44/, response.body, "balance once the cycle has closed")
    assert_match(/Margin in use at start/, response.body)
    assert_match(/\$90\.00/, response.body)
    assert_match(/Trades in this cycle/, response.body)
    assert_match(/Closed below take profit/, response.body)
  end

  test "a cycle with no account sample before it says so instead of showing a figure" do
    base = Time.utc(2026, 10, 13, 15, 28, 53)
    close_position(ticket: "solo", profit: 1.5, opened_at: base - 1.hour, closed_at: base)

    get trading_history_cycle_path(@strategy.positions.find_by!(ticket: "solo").id)

    assert_response :success
    assert_match(/No record/, response.body)
    assert_match(/Balance at start/, response.body)
  end

  test "another account's cycle cannot be opened by id" do
    theirs = users(:unverified).strategies.create!(VALID.merge(name: "theirs"))
    secret = close_position(ticket: "secret", profit: 999, opened_at: 2.hours.ago, closed_at: 1.hour.ago, strategy: theirs)

    get trading_history_cycle_path(secret.id)

    assert_response :not_found
  end

  test "the history list links each cycle to its page" do
    close_position(ticket: "l1", profit: 3, opened_at: 2.hours.ago, closed_at: 1.hour.ago)
    first = @strategy.positions.find_by!(ticket: "l1")

    get trading_history_path(strategy_id: @strategy.id)

    assert_select "a[href=?]", trading_history_cycle_path(first.id)
  end
end
