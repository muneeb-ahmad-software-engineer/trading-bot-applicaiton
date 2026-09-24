require "test_helper"

# The MT5 ingestion and read-back API.
#
# These tests act as a fake Expert Advisor: they post the same payloads a real
# terminal would, which is what keeps the documented integration contract
# honest.
class ApiV1TradingTest < ActionDispatch::IntegrationTest
  VALID_STRATEGY = {
    name: "XAUUSD grid", direction: "both",
    grid_spacing_points: 150, grid_levels: 5,
    initial_lot: 0.01, lot_mode: "fixed",
    max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  setup do
    @user = users(:verified)
    @token_record = ApiToken.issue(user: @user, name: "MT5 terminal")
    @token = @token_record.plaintext_token
    @strategy = @user.strategies.create!(VALID_STRATEGY)
    @strategy.start!
  end

  def headers(token = @token) = { "Authorization" => "Bearer #{token}" }

  def json = JSON.parse(response.body)

  def report(**overrides)
    payload = {
      strategy_id: @strategy.id,
      terminal: { ea_version: "1.0.0", broker: "Demo Broker", account_login: "12345", symbol: "XAUUSD" },
      tick: { bid: "2318.40", ask: "2318.45", spread_points: 5 },
      account: { currency: "USD", balance: "10000.00", equity: "10184.20",
                 margin: "120.00", free_margin: "10064.20", margin_level_percent: "8486.83" },
      positions: [
        { ticket: "1001", direction: "buy", grid_level: 1, volume: "0.01",
          open_price: "2310.20", current_price: "2318.40", profit: "82.00",
          swap: "-1.20", commission: "-0.30", opened_at: 2.hours.ago.iso8601 }
      ],
      orders: [
        { ticket: "2001", order_type: "buy_limit", grid_level: 2, volume: "0.01",
          price: "2295.20", placed_at: 2.hours.ago.iso8601 }
      ]
    }.deep_merge(overrides)

    post "/api/v1/trading/report", params: payload, headers: headers, as: :json
  end

  # ------------------------------------------------------------- Ingestion

  test "ingestion requires a valid token" do
    post "/api/v1/trading/report", params: { strategy_id: @strategy.id }, as: :json
    assert_response :unauthorized
  end

  test "a report records the connection, account, positions and orders" do
    report

    assert_response :accepted
    assert_equal 1, @strategy.positions.open.count
    assert_equal 1, @strategy.orders.pending.count
    assert_equal 1, @user.account_snapshots.count

    connection = @user.terminal_connections.sole
    assert_equal "live", connection.status.to_s
    assert_equal "Demo Broker", connection.broker
  end

  test "reports are idempotent — a repeated report does not duplicate positions" do
    report
    report
    report

    assert_equal 1, @strategy.positions.count, "the same ticket must update one row, not create three"
    assert_equal 1, @strategy.orders.count
  end

  test "live account state is updated in place rather than accumulating" do
    3.times { report }

    # One row per account, upserted. Writing a row per report was 8,640 inserts
    # per user per day to serve reads that only ever wanted the newest.
    assert_equal 1, AccountState.where(user: @user).count
    assert_equal BigDecimal("10184.20"), AccountState.find_by(user: @user).equity
  end

  test "account history is sampled, not written on every report" do
    5.times { report }

    assert_equal 1, @user.account_snapshots.count,
      "history is sampled at #{AccountSnapshot::SAMPLE_INTERVAL.inspect}, not once per report"

    # Once the sampling interval has passed, history records another point.
    travel (AccountSnapshot::SAMPLE_INTERVAL + 1.second) do
      report
      assert_equal 2, @user.account_snapshots.count
    end
  end

  test "a position that stops being reported is marked closed, not deleted" do
    report
    position = @strategy.positions.sole

    report(positions: [])

    assert_equal 1, @strategy.positions.count, "history must survive"
    assert_not position.reload.open?
    assert_not_nil position.closed_at
  end

  test "an order that stops being reported is marked cancelled" do
    report
    order = @strategy.orders.sole

    report(orders: [])

    assert_equal "cancelled", order.reload.status
  end

  test "omitting positions entirely leaves them untouched" do
    report
    # A lightweight heartbeat that carries no position list must not be read as
    # "all positions closed".
    post "/api/v1/trading/report",
         params: { strategy_id: @strategy.id, tick: { bid: "2318.50", ask: "2318.55" } },
         headers: headers, as: :json

    assert_response :accepted
    assert_equal 1, @strategy.positions.open.count, "a heartbeat must not close open positions"
  end

  test "a report for another user's strategy is rejected" do
    theirs = users(:unverified).strategies.create!(VALID_STRATEGY)

    post "/api/v1/trading/report", params: { strategy_id: theirs.id }, headers: headers, as: :json

    assert_response :unprocessable_entity
    assert_equal 0, theirs.positions.count
  end

  test "decimal values survive the round trip exactly" do
    report(account: { balance: "10000.55" }, positions: [ {
      ticket: "1001", direction: "buy", volume: "0.01", open_price: "2310.12345",
      current_price: "2318.40", profit: "0.10", swap: "0.20", commission: "0.30",
      opened_at: 1.hour.ago.iso8601
    } ])

    assert_equal BigDecimal("10000.55"), @user.account_snapshots.last.balance
    position = @strategy.positions.sole
    assert_equal BigDecimal("2310.12345"), position.open_price
    # 0.10 + 0.20 + 0.30 is exactly 0.60 in decimal; in binary floats it is not.
    assert_equal BigDecimal("0.60"), position.net_profit
  end

  # ------------------------------------------------------------- Read-back

  test "account endpoint reports connection state and latest account data" do
    report
    get "/api/v1/trading/account", headers: headers

    assert_response :success
    assert_equal "live", json.dig("connection", "status")
    assert_equal "10184.20", json.dig("account", "equity")
  end

  test "account endpoint distinguishes never-connected from connected" do
    get "/api/v1/trading/account", headers: headers

    assert_equal "never_connected", json.dig("connection", "status")
    assert_nil json["account"]
  end

  test "a connection goes stale on its own once reports stop" do
    report
    connection = @user.terminal_connections.sole
    connection.update!(last_report_at: 10.minutes.ago)

    get "/api/v1/trading/account", headers: headers

    assert_equal "stale", json.dig("connection", "status"),
      "a terminal that stopped reporting must not still read as connected"
  end

  test "positions endpoint returns open positions with a computed basket total" do
    report
    get "/api/v1/trading/positions", headers: headers

    assert_equal 1, json["positions"].size
    # 82.00 - 1.20 - 0.30
    assert_equal "80.50", json.dig("basket", "profit")
    assert_equal 1, json.dig("basket", "open_positions")
  end

  test "orders endpoint returns pending orders only" do
    report
    get "/api/v1/trading/orders", headers: headers

    assert_equal 1, json["orders"].size
    assert_equal "buy_limit", json["orders"].first["order_type"]
  end

  test "history returns closed positions and realised profit" do
    report
    report(positions: [])

    get "/api/v1/trading/history", headers: headers

    assert_equal 1, json["positions"].size
    assert_not_nil json["positions"].first["closed_at"]
    assert_equal "80.50", json["realised_profit"]
  end

  test "money and lot fields always carry a fixed number of decimal places" do
    # A client must never see "0.5" for one request and "0.50" for the next.
    report(account: { balance: "10000.00", equity: "10000.5" })

    get "/api/v1/trading/account", headers: headers
    %w[balance equity].each do |field|
      assert_match(/\A-?\d+\.\d{2}\z/, json.dig("account", field),
        "#{field} must be serialised at a fixed scale, got #{json.dig('account', field).inspect}")
    end

    get "/api/v1/trading/positions", headers: headers
    position = json["positions"].first
    assert_match(/\A-?\d+\.\d{2}\z/, position["volume"])
    assert_match(/\A-?\d+\.\d{2}\z/, position["net_profit"])
    assert_match(/\A-?\d+\.\d{5}\z/, position["open_price"], "prices keep broker precision")
  end

  test "read-back endpoints never expose another account's trading data" do
    report
    other = users(:unverified)
    other_token = ApiToken.issue(user: other, name: "theirs").plaintext_token

    get "/api/v1/trading/positions", headers: headers(other_token)
    assert_empty json["positions"]

    get "/api/v1/trading/account", headers: headers(other_token)
    assert_nil json["account"]

    get "/api/v1/trading/history", headers: headers(other_token)
    assert_empty json["positions"]
  end

  test "revoking a token stops a terminal from reporting" do
    @token_record.revoke!

    report
    assert_response :unauthorized
    assert_equal 0, @strategy.positions.count
  end
end
