require "test_helper"

# The strategy API: what the MT5 Expert Advisor polls, and what a mobile client
# uses to configure and control a bot.
class ApiV1StrategiesTest < ActionDispatch::IntegrationTest
  VALID = {
    name: "XAUUSD grid", direction: "both",
    grid_spacing_points: 150, grid_levels: 5,
    initial_lot: 0.01, lot_mode: "fixed",
    max_positions: 10, max_exposure_lots: 0.5
  }.freeze

  setup do
    @user = users(:verified)
    @token = ApiToken.issue(user: @user, name: "MT5 terminal").plaintext_token
  end

  def headers(token = @token) = { "Authorization" => "Bearer #{token}" }

  def json = JSON.parse(response.body)

  test "requires a token for every strategy endpoint" do
    strategy = @user.strategies.create!(VALID)

    get "/api/v1/strategies"
    assert_response :unauthorized

    get "/api/v1/strategies/#{strategy.id}"
    assert_response :unauthorized

    post "/api/v1/strategies/#{strategy.id}/start"
    assert_response :unauthorized
  end

  test "lists only the token owner's strategies" do
    @user.strategies.create!(VALID.merge(name: "mine"))
    users(:unverified).strategies.create!(VALID.merge(name: "not mine"))

    get "/api/v1/strategies", headers: headers

    assert_response :success
    names = json["strategies"].map { _1["name"] }
    assert_includes names, "mine"
    assert_not_includes names, "not mine"
  end

  test "returns the full configuration an Expert Advisor needs" do
    strategy = @user.strategies.create!(VALID)

    get "/api/v1/strategies/#{strategy.id}", headers: headers

    payload = json["strategy"]
    assert_equal "XAUUSD", payload["symbol"]
    assert_equal 150, payload.dig("grid", "spacing_points")
    assert_equal 5, payload.dig("grid", "levels")
    assert_equal 10, payload.dig("risk", "max_positions")
    assert_equal "draft", payload["status"]
  end

  test "numeric values are serialised as strings to preserve decimal precision" do
    strategy = @user.strategies.create!(VALID.merge(initial_lot: 0.01))

    get "/api/v1/strategies/#{strategy.id}", headers: headers

    # A JSON float would reintroduce the binary rounding the decimal columns exist to avoid.
    assert_equal "0.01", json.dig("strategy", "grid", "initial_lot")
    assert_kind_of String, json.dig("strategy", "risk", "max_exposure_lots")
  end

  test "creates a strategy and reports validation errors in a machine-readable shape" do
    assert_difference "Strategy.count", 1 do
      post "/api/v1/strategies", params: { strategy: VALID }, headers: headers, as: :json
    end
    assert_response :created

    post "/api/v1/strategies", params: { strategy: VALID.merge(grid_levels: 0) }, headers: headers, as: :json

    assert_response :unprocessable_entity
    assert_equal "validation_failed", json.dig("error", "code")
    assert json.dig("error", "details").key?("grid_levels")
  end

  test "start and stop drive the lifecycle" do
    strategy = @user.strategies.create!(VALID)

    post "/api/v1/strategies/#{strategy.id}/start", headers: headers
    assert_response :success
    assert_equal "running", json.dig("strategy", "status")

    post "/api/v1/strategies/#{strategy.id}/stop", headers: headers
    assert_equal "stopped", json.dig("strategy", "status")
  end

  test "an emergency stop is available over the API and reaches the EA payload" do
    strategy = @user.strategies.create!(VALID)
    strategy.start!

    post "/api/v1/strategies/#{strategy.id}/emergency_stop", headers: headers

    assert_response :success
    assert_equal "stopped", json.dig("strategy", "status")
    assert_equal true, json.dig("strategy", "risk", "emergency_stop")
  end

  test "a running strategy's configuration can be changed" do
    strategy = @user.strategies.create!(VALID)
    strategy.start!

    patch "/api/v1/strategies/#{strategy.id}", params: { strategy: { grid_levels: 8, max_exposure_lots: 1.0 } }, headers: headers, as: :json
    assert_response :success
    assert_equal 8, strategy.reload.grid_levels
    assert_predicate strategy, :running?
  end

  test "an unverified user cannot start a strategy but can always stop one" do
    user = users(:unverified)
    token = ApiToken.issue(user:, name: "iPhone").plaintext_token
    strategy = user.strategies.create!(VALID)

    post "/api/v1/strategies/#{strategy.id}/start", headers: headers(token)
    assert_response :forbidden
    assert_equal "email_unverified", json.dig("error", "code")

    # Stopping must never be gated — a user must always be able to halt.
    strategy.update_column(:status, "running")
    post "/api/v1/strategies/#{strategy.id}/stop", headers: headers(token)
    assert_response :success
  end

  test "a second strategy cannot start while one is running" do
    first = @user.strategies.create!(VALID.merge(name: "first"))
    first.start!
    second = @user.strategies.create!(VALID.merge(name: "second"))

    post "/api/v1/strategies/#{second.id}/start", headers: headers

    assert_response :conflict
    assert_equal "already_running", json.dig("error", "code")
  end

  test "a token cannot reach another account's strategy" do
    theirs = users(:unverified).strategies.create!(VALID.merge(name: "theirs"))

    get "/api/v1/strategies/#{theirs.id}", headers: headers
    assert_response :not_found

    post "/api/v1/strategies/#{theirs.id}/start", headers: headers
    assert_response :not_found

    patch "/api/v1/strategies/#{theirs.id}", params: { strategy: { name: "hijacked" } }, headers: headers, as: :json
    assert_response :not_found
    assert_equal "theirs", theirs.reload.name
  end

  test "a revoked token loses strategy access immediately" do
    strategy = @user.strategies.create!(VALID)
    token = ApiToken.issue(user: @user, name: "revoke me")

    get "/api/v1/strategies/#{strategy.id}", headers: headers(token.plaintext_token)
    assert_response :success

    token.revoke!

    get "/api/v1/strategies/#{strategy.id}", headers: headers(token.plaintext_token)
    assert_response :unauthorized
  end
end
