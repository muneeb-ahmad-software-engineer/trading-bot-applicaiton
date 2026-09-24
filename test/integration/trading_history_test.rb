require "test_helper"

class TradingHistoryTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  VALID = {
    name: "XAUUSD grid", direction: "both",
    grid_spacing_points: 150, grid_levels: 5,
    initial_lot: 0.01, lot_mode: "fixed",
    max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  setup do
    @user = users(:verified)
    @strategy = @user.strategies.create!(VALID)
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
  end

  def close_position(ticket:, profit: 10, direction: "buy", closed_at: 1.hour.ago, strategy: @strategy)
    strategy.positions.create!(
      ticket:, direction:, volume: 0.01,
      open_price: 2300, close_price: 2310, profit:, swap: 0, commission: 0,
      opened_at: closed_at - 1.hour, closed_at:
    )
  end

  test "lists closed positions with realised profit for the filtered set" do
    close_position(ticket: "1", profit: 50)
    close_position(ticket: "2", profit: -20)

    get trading_history_path

    assert_response :success
    assert_select "table"
    # 50 - 20, with an explicit sign.
    assert_match(/\+30\.00/, response.body)
  end

  test "open positions never appear in history" do
    @strategy.positions.create!(ticket: "open", direction: "buy", volume: 0.01,
                               open_price: 2300, opened_at: 1.hour.ago)

    get trading_history_path

    assert_no_match(/open/, css_select("tbody").text)
  end

  test "filters by strategy, direction and date" do
    other = @user.strategies.create!(VALID.merge(name: "other"))
    close_position(ticket: "mine", profit: 10)
    close_position(ticket: "theirs", profit: 10, strategy: other)
    close_position(ticket: "sell1", profit: 10, direction: "sell")
    close_position(ticket: "old", profit: 10, closed_at: 40.days.ago)

    get trading_history_path(strategy_id: other.id)
    assert_match "theirs", css_select("tbody").text
    assert_no_match(/mine/, css_select("tbody").text)

    get trading_history_path(direction: "sell")
    assert_match "sell1", css_select("tbody").text
    assert_no_match(/mine/, css_select("tbody").text)

    get trading_history_path(from: 7.days.ago.to_date.to_s)
    assert_no_match(/old/, css_select("tbody").text)
  end

  test "an invalid filter is ignored rather than erroring" do
    close_position(ticket: "1")

    get trading_history_path(direction: "sideways", from: "not-a-date")

    assert_response :success
    assert_match "1", css_select("tbody").text
  end

  test "another account's history is unreachable even by explicit id" do
    theirs = users(:unverified).strategies.create!(VALID.merge(name: "theirs"))
    close_position(ticket: "secret", profit: 999, strategy: theirs)

    get trading_history_path(strategy_id: theirs.id)

    assert_response :success
    assert_no_match(/secret/, response.body)
  end

  test "pagination splits results and totals cover the whole set" do
    30.times { |i| close_position(ticket: "t#{i}", profit: 1) }

    get trading_history_path

    assert_select "tbody tr", TradingHistoryController::PER_PAGE
    # The realised total must describe every match, not the visible page.
    assert_match(/\+30\.00/, response.body)

    get trading_history_path(page: 2)
    assert_select "tbody tr", 5
  end

  test "empty states distinguish no data from no matches" do
    get trading_history_path
    assert_match(/will appear here once your terminal reports/i, response.body)

    close_position(ticket: "1")
    get trading_history_path(direction: "sell")
    assert_match(/no positions match these filters/i, response.body)
  end

  test "the SQL realised total matches the Ruby net_profit definition" do
    # The controller sums in SQL for speed. If Position#net_profit changes and
    # that expression does not, the page would quietly report a wrong total.
    close_position(ticket: "a", profit: 10)
    close_position(ticket: "b", profit: -3)
    Position.find_by(ticket: "a").update!(swap: -1.5, commission: -0.25)
    Position.find_by(ticket: "b").update!(swap: nil, commission: nil)

    scope = Position.where(strategy: @strategy).closed
    ruby_total = scope.sum(&:net_profit)
    sql_total = scope.sum(TradingHistoryController::NET_PROFIT_SQL)

    assert_equal ruby_total.to_d, sql_total.to_d
  end

  test "history requires authentication" do
    delete logout_path
    get trading_history_path

    assert_redirected_to login_path
  end
end
