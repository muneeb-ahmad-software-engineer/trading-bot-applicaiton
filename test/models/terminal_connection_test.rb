require "test_helper"

class TerminalConnectionTest < ActiveSupport::TestCase
  setup do
    @user = users(:verified)
    @token = ApiToken.issue(user: @user, name: "MT5 terminal")
  end

  def build(**overrides)
    TerminalConnection.new({ user: @user, api_token: @token, symbol: "XAUUSD" }.merge(overrides))
  end

  test "a terminal that has never reported is not live" do
    connection = build(last_report_at: nil)

    assert_equal :never_connected, connection.status
    assert_not connection.live?
  end

  test "a recently reporting terminal is live" do
    connection = build(last_report_at: 5.seconds.ago)

    assert_equal :live, connection.status
    assert_predicate connection, :live?
  end

  test "a terminal that stopped reporting goes stale without anyone updating it" do
    # Liveness is derived, not stored: nothing has to run to expire it.
    connection = build(last_report_at: (TerminalConnection::STALE_AFTER + 1.second).ago)

    assert_equal :stale, connection.status
    assert_not connection.live?
  end

  test "spread is derived from the quote when the terminal does not send it" do
    connection = build(bid: BigDecimal("2318.40"), ask: BigDecimal("2318.45"), spread_points: nil)

    assert_equal 5, connection.spread_points_or_derived
  end

  test "a reported spread is preferred over a derived one" do
    connection = build(bid: BigDecimal("2318.40"), ask: BigDecimal("2318.45"), spread_points: 7)

    assert_equal 7, connection.spread_points_or_derived
  end

  test "one connection per API token, so revoking a token disconnects a terminal" do
    TerminalConnection.create!(user: @user, api_token: @token, symbol: "XAUUSD")

    assert_raises(ActiveRecord::RecordNotUnique) do
      TerminalConnection.create!(user: @user, api_token: @token, symbol: "XAUUSD")
    end
  end
end
