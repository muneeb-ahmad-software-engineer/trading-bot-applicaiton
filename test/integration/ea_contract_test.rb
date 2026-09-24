require "test_helper"

# Cross-check between the Expert Advisor and the platform.
#
# The MQL5 EA cannot be compiled or run here, so the half of the contract that
# CAN be verified is the payload it produces. The JSON below is written to match
# BuildReportJson() in mt5/GoldGrid.mq5 exactly — same key order, same string
# quoting of numbers, same empty orders array.
#
# If someone changes the EA's payload or the platform's expectations without
# changing the other, this test fails. That is the only automated protection the
# integration has until the EA is run against a demo account.
class EaContractTest < ActionDispatch::IntegrationTest
  VALID_STRATEGY = {
    name: "XAUUSD grid", direction: "both",
    grid_spacing_points: 150, grid_levels: 5,
    initial_lot: 0.01, lot_mode: "fixed",
    max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  setup do
    @user = users(:verified)
    @token = ApiToken.issue(user: @user, name: "MT5 terminal").plaintext_token
    @strategy = @user.strategies.create!(VALID_STRATEGY)
    @strategy.start!
  end

  def headers
    { "Authorization" => "Bearer #{@token}", "Content-Type" => "application/json" }
  end

  # Byte-for-byte the shape BuildReportJson() emits.
  def ea_payload(strategy_id: @strategy.id, positions: :one)
    position = <<~JSON.strip
      {"ticket":"1001","direction":"buy","grid_level":1,"volume":"0.01",\
      "open_price":"2310.20","current_price":"2318.40","stop_loss":"2316.40",\
      "profit":"82.00",\
      "swap":"-1.20","commission":"0.00","opened_at":"2026-09-06T06:00:00Z"}
    JSON

    <<~JSON.gsub(/\n\s*/, "")
      {"strategy_id":#{strategy_id},
       "terminal":{"ea_version":"1.00","broker":"Demo Broker Ltd","account_login":"12345678","symbol":"XAUUSD"},
       "tick":{"bid":"2318.40","ask":"2318.45","spread_points":5},
       "account":{"currency":"USD","balance":"10000.00","equity":"10182.50","margin":"120.00",
                  "free_margin":"10062.50","margin_level_percent":"8485.42"},
       "positions":[#{positions == :one ? position : ''}],
       "orders":[]}
    JSON
  end

  test "the platform accepts the exact payload the EA builds" do
    post "/api/v1/trading/report", params: ea_payload, headers: headers

    assert_response :accepted, "the EA's report payload was rejected: #{response.body}"
  end

  test "every field the EA sends is actually stored" do
    post "/api/v1/trading/report", params: ea_payload, headers: headers

    connection = @user.terminal_connections.sole
    assert_equal "1.00", connection.ea_version
    assert_equal "Demo Broker Ltd", connection.broker
    assert_equal "12345678", connection.account_login
    assert_equal "XAUUSD", connection.symbol
    assert_equal BigDecimal("2318.40"), connection.bid
    assert_equal 5, connection.spread_points

    snapshot = @user.account_snapshots.sole
    assert_equal "USD", snapshot.currency
    assert_equal BigDecimal("10000.00"), snapshot.balance
    assert_equal BigDecimal("10182.50"), snapshot.equity
    assert_equal BigDecimal("8485.42"), snapshot.margin_level_percent

    position = @strategy.positions.sole
    assert_equal "1001", position.ticket
    assert_equal "buy", position.direction
    assert_equal 1, position.grid_level
    assert_equal BigDecimal("0.01"), position.volume
    assert_equal BigDecimal("2310.20"), position.open_price
    assert_equal BigDecimal("2316.40"), position.stop_loss
    # 82.00 - 1.20 + 0.00
    assert_equal BigDecimal("80.80"), position.net_profit
  end

  test "the EA's always-empty orders array does not error" do
    post "/api/v1/trading/report", params: ea_payload, headers: headers

    assert_response :accepted
    assert_equal 0, @strategy.orders.count
  end

  test "repeated identical reports stay idempotent, as the EA relies on" do
    3.times { post "/api/v1/trading/report", params: ea_payload, headers: headers }

    assert_equal 1, @strategy.positions.count
  end

  test "an empty positions array closes the basket, as the EA intends after an exit" do
    post "/api/v1/trading/report", params: ea_payload, headers: headers
    position = @strategy.positions.sole

    post "/api/v1/trading/report", params: ea_payload(positions: :none), headers: headers

    assert_not position.reload.open?,
      "after the EA closes a basket it reports an empty array, which must close the records"
  end

  test "a report naming an unknown strategy is refused, not silently accepted" do
    post "/api/v1/trading/report", params: ea_payload(strategy_id: 999_999), headers: headers

    assert_response :unprocessable_entity
  end

  test "the strategy payload the EA parses contains every field it needs" do
    get "/api/v1/strategies/#{@strategy.id}", headers: headers

    strategy = JSON.parse(response.body).fetch("strategy")

    # Each of these is read by ParseStrategy() in Strategy.mqh. A rename here
    # would make the EA refuse to trade.
    assert strategy.key?("id")
    assert strategy.key?("status")
    assert strategy.key?("symbol")
    assert strategy.key?("direction")
    assert strategy.key?("category")
    %w[stop_points activation_points step_points].each do |key|
      assert strategy.fetch("trailing").key?(key), "trailing.#{key} missing — the EA reads it"
    end
    %w[spacing_points levels initial_lot lot_mode lot_multiplier].each do |key|
      assert strategy.fetch("grid").key?(key), "grid.#{key} missing — the EA reads it"
    end
    %w[take_profit stop_loss].each do |key|
      assert strategy.fetch("basket").key?(key), "basket.#{key} missing — the EA reads it"
    end
    %w[max_positions max_exposure_lots max_drawdown_percent
       min_margin_level_percent max_spread_points].each do |key|
      assert strategy.fetch("risk").key?(key), "risk.#{key} missing — the EA enforces it"
    end
  end

  # MT5 reports a position with no stop attached as a stop price of zero. The
  # platform must not store that as a price, or every untrailed position shows
  # a stop level of 0.00000.
  test "a zero stop from the terminal is stored as no stop at all" do
    payload = ea_payload.sub('"stop_loss":"2316.40"', '"stop_loss":"0.00"')

    post "/api/v1/trading/report", params: payload, headers: headers

    assert_response :accepted
    assert_nil @strategy.positions.sole.stop_loss
  end

  # A trailing strategy sends null spacing and levels. ParseStrategy() accepts
  # that for this category, so the platform has to be able to emit it.
  test "a trailing strategy serialises with no grid and a distance the EA can read" do
    @strategy.stop!
    trailing = @user.strategies.create!(
      name: "XAUUSD trailing", category: "trailing", direction: "both",
      initial_lot: 0.01, trailing_stop_points: 200,
      max_positions: 10, max_exposure_lots: 0.5
    )

    get "/api/v1/strategies/#{trailing.id}", headers: headers

    strategy = JSON.parse(response.body).fetch("strategy")
    assert_equal "trailing", strategy.fetch("category")
    assert_nil strategy.dig("grid", "spacing_points")
    assert_nil strategy.dig("grid", "levels")
    assert_equal 200, strategy.dig("trailing", "stop_points")
    assert_nil strategy.dig("trailing", "activation_points")
    # Never null: the EA would otherwise modify the position on every tick.
    assert_equal Strategy::TRAILING_STEP_DEFAULT_POINTS, strategy.dig("trailing", "step_points")
  end

  test "status values the EA branches on are exactly the ones emitted" do
    get "/api/v1/strategies/#{@strategy.id}", headers: headers
    assert_equal "running", JSON.parse(response.body).dig("strategy", "status")

    @strategy.stop!
    get "/api/v1/strategies/#{@strategy.id}", headers: headers
    assert_equal "stopped", JSON.parse(response.body).dig("strategy", "status")
  end
end
