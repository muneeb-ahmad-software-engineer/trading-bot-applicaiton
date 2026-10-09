require "test_helper"

# The audit trail must actually capture the actions that matter. These assert
# the recording is wired up, not merely that the Event model works.
class AuditTrailTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  VALID = {
    name: "XAUUSD grid", direction: "both",
    grid_spacing_points: 150, grid_buy_orders: 5, grid_sell_orders: 5, basket_take_profit: 2,
    initial_lot: 0.01,
    max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  setup do
    @user = users(:verified)
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
  end

  def actions = @user.events.pluck(:action)

  test "signing in is recorded" do
    assert_includes actions, "session.started"
  end

  test "the strategy lifecycle is recorded" do
    post strategies_path, params: { strategy: VALID }
    strategy = Strategy.last

    post start_strategy_path(strategy)
    post stop_strategy_path(strategy)

    assert_includes actions, "strategy.created"
    assert_includes actions, "strategy.started"
    assert_includes actions, "strategy.stopped"
  end

  test "starting records the configuration that went live" do
    post strategies_path, params: { strategy: VALID }
    strategy = Strategy.last
    post start_strategy_path(strategy)

    event = @user.events.find_by(action: "strategy.started")

    # Captured at start, so editing afterwards cannot rewrite what was run.
    assert_equal "XAUUSD", event.metadata["symbol"]
    assert_equal 5, event.metadata["grid_buy_orders"]
    assert_equal "0.1", event.metadata["maximum_theoretical_lots"]
  end

  test "issuing and revoking an API token is recorded" do
    post api_tokens_path, params: { api_token: { name: "MT5 terminal" } }
    token = ApiToken.last
    delete api_token_path(token)

    assert_includes actions, "api_token.issued"
    assert_includes actions, "api_token.revoked"
    assert_equal "MT5 terminal", @user.events.find_by(action: "api_token.issued").metadata["name"]
  end

  test "two-factor changes are recorded" do
    @user.prepare_otp_secret!
    post two_factor_settings_path, params: { code: ROTP::TOTP.new(@user.reload.otp_secret).now }

    assert_includes actions, "two_factor.enabled"
  end

  test "API actions are distinguishable from web actions" do
    strategy = @user.strategies.create!(VALID)
    token = ApiToken.issue(user: @user, name: "MT5").plaintext_token

    post "/api/v1/strategies/#{strategy.id}/start",
         headers: { "Authorization" => "Bearer #{token}" }

    event = @user.events.where(action: "strategy.started").last
    assert_equal "api", event.source
  end

  test "activity is visible to its owner and scoped to them" do
    other = users(:unverified)
    Event.record("strategy.started", user: other, metadata: { name: "not mine" })

    get activity_path

    assert_response :success
    assert_match(/Signed in/, response.body)
    assert_no_match(/not mine/, response.body)
  end
end
