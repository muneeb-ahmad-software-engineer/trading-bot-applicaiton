require "test_helper"

# Serializers define the API wire format in one place.
#
# Before this layer existed the same resource was serialised inside three
# controllers and could drift apart. These tests hold the format still, because
# the MT5 Expert Advisor parses it by key.
class SerializerTest < ActiveSupport::TestCase
  setup do
    @user = users(:verified)
    @strategy = @user.strategies.create!(
      name: "XAUUSD grid", grid_spacing_points: 150, grid_buy_orders: 5, grid_sell_orders: 5,
      initial_lot: 0.01, max_positions: 10, max_exposure_lots: 0.5,
      max_drawdown_percent: 20, basket_take_profit: 250
    )
  end

  test "decimals are emitted as fixed-scale strings, never floats" do
    payload = StrategySerializer.new(@strategy).as_json

    assert_equal "0.01", payload.dig(:grid, :initial_lot)
    assert_equal "0.50", payload.dig(:risk, :max_exposure_lots)
    assert_equal "250.00", payload.dig(:basket, :take_profit)
    assert_equal "20.00", payload.dig(:risk, :max_drawdown_percent)

    [ payload.dig(:grid, :initial_lot), payload.dig(:risk, :max_exposure_lots) ].each do |value|
      assert_kind_of String, value
      assert_match(/\A-?\d+\.\d{2}\z/, value)
    end
  end

  test "absent optional values are null rather than zero" do
    payload = StrategySerializer.new(@strategy).as_json

    # A missing stop loss means "no stop loss", not "a stop loss of nothing".
    assert_nil payload.dig(:basket, :stop_loss)
    assert_nil payload.dig(:risk, :min_margin_level_percent)
  end

  test "prices keep broker precision while money keeps two places" do
    position = @strategy.positions.create!(
      ticket: "1", direction: "buy", volume: 0.01,
      open_price: BigDecimal("2310.12345"), profit: BigDecimal("82.5"),
      swap: BigDecimal("-1.2"), commission: BigDecimal("-0.3"),
      opened_at: Time.current
    )

    payload = PositionSerializer.new(position).as_json

    assert_equal "2310.12345", payload[:open_price]
    assert_equal "82.50", payload[:profit]
    assert_equal "81.00", payload[:net_profit]
  end

  test "a never-connected terminal is a distinct state from a connected one" do
    assert_equal({ status: "never_connected" }, TerminalConnectionSerializer.for(nil))
  end

  test "collection serialisation matches single serialisation" do
    other = @user.strategies.create!(
      name: "second", grid_spacing_points: 100, grid_buy_orders: 3, grid_sell_orders: 2,
      basket_take_profit: 2, initial_lot: 0.01, max_positions: 5, max_exposure_lots: 0.5
    )

    collection = StrategySerializer.collection([ @strategy, other ])

    assert_equal 2, collection.size
    assert_equal StrategySerializer.new(@strategy).as_json, collection.first
  end

  test "user serializer never leaks credentials" do
    @user.prepare_otp_secret!
    payload = UserSerializer.new(@user).as_json.to_json

    assert_no_match(/password/i, payload)
    assert_no_match(/otp_secret/i, payload)
    assert_no_match(/#{Regexp.escape(@user.otp_secret)}/, payload)
    assert_no_match(/token/i, payload)
  end

  test "every serializer implements as_json" do
    ApplicationSerializer.subclasses.each do |serializer|
      assert serializer.instance_methods(false).include?(:as_json),
        "#{serializer} does not define as_json"
    end
  end
end
