require "test_helper"

# The lifecycle rules must behave identically however they are reached. Before
# this layer, the web and API controllers each had their own copy of them.
class StrategiesServiceTest < ActiveSupport::TestCase
  VALID = {
    name: "XAUUSD grid", direction: "both",
    grid_spacing_points: 150, grid_buy_orders: 5, grid_sell_orders: 5, basket_take_profit: 2,
    initial_lot: 0.01,
    max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  setup do
    @user = users(:verified)
    @strategy = @user.strategies.create!(VALID)
  end

  test "starting succeeds and records an event" do
    assert_difference -> { @user.events.count }, 1 do
      result = Strategies::Start.call(strategy: @strategy, actor: @user)
      assert_predicate result, :success?
    end

    assert_predicate @strategy.reload, :running?
    assert_equal "strategy.started", @user.events.last.action
  end

  test "an unverified user cannot start and no event is written" do
    user = users(:unverified)
    strategy = user.strategies.create!(VALID)

    assert_no_difference -> { user.events.count } do
      result = Strategies::Start.call(strategy:, actor: user)

      assert_predicate result, :failure?
      assert_equal "email_unverified", result.error_code
    end

    assert_not strategy.reload.running?
  end

  test "a second strategy cannot start while one runs" do
    Strategies::Start.call(strategy: @strategy, actor: @user)
    second = @user.strategies.create!(VALID.merge(name: "second"))

    result = Strategies::Start.call(strategy: second, actor: @user)

    assert_predicate result, :failure?
    assert_equal "already_running", result.error_code
    assert_not second.reload.running?
  end

  test "starting an already-running strategy is refused" do
    Strategies::Start.call(strategy: @strategy, actor: @user)

    result = Strategies::Start.call(strategy: @strategy, actor: @user)

    assert_predicate result, :failure?
    assert_equal "already_running", result.error_code
  end

  test "stopping is never blocked, even for an unverified user" do
    user = users(:unverified)
    strategy = user.strategies.create!(VALID)
    strategy.update_column(:status, "running")

    result = Strategies::Stop.call(strategy:, actor: user)

    # Halting must always be possible. If a user wants to stop, they stop.
    assert_predicate result, :success?
    assert_predicate strategy.reload, :stopped?
  end

  test "the source is recorded so web and API actions are distinguishable" do
    Strategies::Start.call(strategy: @strategy, actor: @user, source: "api", ip_address: "9.9.9.9")

    event = @user.events.last
    assert_equal "api", event.source
    assert_equal "9.9.9.9", event.ip_address
  end

  test "the started event captures the configuration that went live" do
    Strategies::Start.call(strategy: @strategy, actor: @user)

    metadata = @user.events.find_by(action: "strategy.started").metadata

    assert_equal "XAUUSD", metadata["symbol"]
    assert_equal 5, metadata["grid_buy_orders"]
    assert_equal "0.1", metadata["maximum_theoretical_lots"]
  end

  test "a failure result carries a stable code for clients to branch on" do
    result = Strategies::Start.call(strategy: @strategy, actor: users(:unverified))

    assert_kind_of ApplicationService::Result, result
    assert_equal "email_unverified", result.error_code
    assert result.error_message.present?
  end
end
