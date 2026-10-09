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
    grid_spacing_points: 150, grid_buy_orders: 5, grid_sell_orders: 5, basket_take_profit: 2,
    initial_lot: 0.01,
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
       "execution":{"state":"BUY_ACTIVE","reason":"entry filled","reversal_level":"2316.40",
                    "daily_profit":"-12.50","risk_halt":"",
                    "cycle":null,"resting_orders":null,"filled_orders":null,"basket_profit":null,"pause_seconds_left":null},
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
    assert_equal "BUY_ACTIVE", connection.execution_state
    assert_equal "entry filled", connection.execution_reason
    assert_equal BigDecimal("2316.40"), connection.reversal_level
    assert_equal BigDecimal("-12.50"), connection.daily_profit
    assert_nil connection.risk_halt, "an empty halt means none"

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

  # The EA re-fetches its configuration when the report response names a
  # different version, which is how a stop or an emergency stop reaches it
  # within one report instead of one refresh interval.
  test "the report response carries the configuration version the EA compares" do
    get "/api/v1/strategies/#{@strategy.id}", headers: headers
    held = JSON.parse(response.body).dig("strategy", "config_version")

    post "/api/v1/trading/report", params: ea_payload, headers: headers
    assert_equal held, JSON.parse(response.body)["config_version"]

    travel 1.second do
      Strategies::EmergencyStop.call(strategy: @strategy, actor: @user)
      post "/api/v1/trading/report", params: ea_payload, headers: headers
      assert_not_equal held, JSON.parse(response.body)["config_version"]
    end
  end

  # A grid EA's execution block (mt5/Include/GoldGrid/Cycle.mqh): the cycle it
  # is on, how many ladder rungs rest and have filled, the basket's floating
  # P/L, and the pause left between cycles — null for the other categories.
  test "a grid EA's cycle is stored beside its execution state" do
    grid_execution = '"execution":{"state":"ARMED","reason":"ladder complete — 58 resting, 2 filled, 0 skipped, capacity 60",' \
                     '"reversal_level":"0.00000","daily_profit":"1.10","risk_halt":"",' \
                     '"cycle":3,"resting_orders":58,"filled_orders":2,"basket_profit":"-0.84","pause_seconds_left":0},'
    payload = ea_payload.sub(/"execution":\{[^}]*\},/, grid_execution)

    post "/api/v1/trading/report", params: payload, headers: headers

    assert_response :accepted
    connection = @user.terminal_connections.sole
    assert_equal "ARMED", connection.execution_state
    assert_equal 3, connection.cycle_number
    assert_equal 58, connection.resting_orders
    assert_equal 2, connection.filled_orders
    assert_equal BigDecimal("-0.84"), connection.basket_profit
    assert_equal 0, connection.pause_seconds_left
    assert_nil connection.reversal_level, "a zero reversal level means none"
  end

  test "a report without the grid figures clears them" do
    post "/api/v1/trading/report", params: ea_payload, headers: headers

    connection = @user.terminal_connections.sole
    assert_nil connection.cycle_number
    assert_nil connection.resting_orders
    assert_nil connection.basket_profit
  end

  test "a ladder order's rung is stored as its grid level" do
    order = '{"ticket":"5001","order_type":"buy_stop","grid_level":4,"volume":"0.01","price":"2326.45",' \
            '"placed_at":"2026-09-06T06:00:00Z"}'
    post "/api/v1/trading/report", params: ea_payload.sub('"orders":[]', "\"orders\":[#{order}]"), headers: headers

    assert_response :accepted
    assert_equal 4, @strategy.orders.find_by(ticket: "5001").grid_level
  end

  test "an EA older than the state machine still reports, with no state stored" do
    post "/api/v1/trading/report", params: ea_payload.sub(/"execution":\{[^}]*\},/, ""), headers: headers

    assert_response :accepted
    assert_nil @user.terminal_connections.sole.execution_state
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
    %w[spacing_points buy_stop_orders sell_stop_orders cycle_pause_seconds initial_lot].each do |key|
      assert strategy.fetch("grid").key?(key), "grid.#{key} missing — the EA reads it"
    end
    %w[take_profit stop_loss].each do |key|
      assert strategy.fetch("basket").key?(key), "basket.#{key} missing — the EA reads it"
    end
    assert strategy.fetch("entry").key?("distance_points"), "entry.distance_points missing — the EA reads it"
    assert strategy.key?("config_version"), "config_version missing — the EA compares it with report responses"
    %w[max_positions max_exposure_lots max_drawdown_percent
       min_margin_level_percent max_spread_points max_daily_loss emergency_stop].each do |key|
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

  # A trailing strategy sends a null ladder. ParseStrategy() accepts that for
  # this category, so the platform has to be able to emit it.
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
    assert_nil strategy.dig("grid", "buy_stop_orders")
    assert_nil strategy.dig("grid", "sell_stop_orders")
    assert_nil strategy.dig("grid", "cycle_pause_seconds")
    assert_equal 200, strategy.dig("trailing", "stop_points")
    assert_nil strategy.dig("trailing", "activation_points")
    # Never null: the EA would otherwise modify the position on every tick.
    assert_equal Strategy::TRAILING_STEP_DEFAULT_POINTS, strategy.dig("trailing", "step_points")
  end

  # The flat bracket distance is sent as the value the EA should use, so a
  # blank field reaches the terminal as the trailing distance, not as null.
  test "a reversal strategy sends its effective entry distance" do
    @strategy.stop!
    reversal = @user.strategies.create!(
      name: "XAUUSD reversal", category: "reversal", direction: "both",
      initial_lot: 0.01, trailing_stop_points: 200,
      max_positions: 1, max_exposure_lots: 0.5
    )

    get "/api/v1/strategies/#{reversal.id}", headers: headers
    assert_equal 200, JSON.parse(response.body).dig("strategy", "entry", "distance_points")

    reversal.update!(entry_distance_points: 350)
    get "/api/v1/strategies/#{reversal.id}", headers: headers
    assert_equal 350, JSON.parse(response.body).dig("strategy", "entry", "distance_points")
  end

  test "status values the EA branches on are exactly the ones emitted" do
    get "/api/v1/strategies/#{@strategy.id}", headers: headers
    assert_equal "running", JSON.parse(response.body).dig("strategy", "status")

    @strategy.stop!
    get "/api/v1/strategies/#{@strategy.id}", headers: headers
    assert_equal "stopped", JSON.parse(response.body).dig("strategy", "status")
  end
end
