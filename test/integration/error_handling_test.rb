require "test_helper"

# Error responses.
#
# The rule: everything under /api answers in JSON, including its failures. A
# mobile client or the MT5 Expert Advisor that receives an HTML error page
# cannot parse it, and would fail with a parse error instead of reading a
# status code it could act on.
class ErrorHandlingTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:verified)
    @token = ApiToken.issue(user: @user, name: "MT5").plaintext_token
  end

  def headers = { "Authorization" => "Bearer #{@token}" }

  # Exercises config.exceptions_app the way production reaches it. Both switches
  # are needed: show_exceptions makes the middleware render rather than raise,
  # and show_detailed_exceptions must be off or DebugExceptions renders its own
  # diagnostic page and the exceptions app is never reached at all.
  def with_error_rendering
    config = Rails.application.env_config
    previous = config.values_at("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")

    config["action_dispatch.show_exceptions"] = :all
    config["action_dispatch.show_detailed_exceptions"] = false
    yield
  ensure
    config["action_dispatch.show_exceptions"], config["action_dispatch.show_detailed_exceptions"] = previous
  end

  test "an API resource that does not exist answers in JSON" do
    get "/api/v1/strategies/999999", headers: headers

    assert_response :not_found
    assert_equal "application/json", response.media_type
    assert_equal "not_found", JSON.parse(response.body).dig("error", "code")
  end

  test "missing parameters answer in JSON with a stable code" do
    post "/api/v1/strategies", params: {}.to_json,
         headers: headers.merge("Content-Type" => "application/json")

    assert_response :bad_request
    assert_equal "bad_request", JSON.parse(response.body).dig("error", "code")
  end

  test "validation failures carry per-field detail a client can act on" do
    post "/api/v1/strategies",
         params: { strategy: { name: "x", grid_spacing_points: 0 } }.to_json,
         headers: headers.merge("Content-Type" => "application/json")

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "validation_failed", body.dig("error", "code")
    assert body.dig("error", "details").present?
  end

  test "an unknown API route answers in JSON, never HTML" do
    with_error_rendering do
      get "/api/v1/no-such-endpoint", headers: headers
    end

    assert_response :not_found
    assert_equal "application/json", response.media_type,
      "an API client cannot parse an HTML error page"
    assert_equal "not_found", JSON.parse(response.body).dig("error", "code")
  end

  test "an unknown page answers in styled HTML" do
    with_error_rendering { get "/no-such-page" }

    assert_response :not_found
    assert_equal "text/html", response.media_type
    assert_select "h1", /not found/i
    assert_select "a[href=?]", root_path
  end

  test "the error page is not indexable" do
    with_error_rendering { get "/no-such-page" }

    assert_select "meta[name=robots][content=?]", "noindex"
  end

  test "an API client sending Accept: */* still receives JSON" do
    with_error_rendering do
      get "/api/v1/no-such-endpoint", headers: headers.merge("Accept" => "*/*")
    end

    # Both curl and the MT5 terminal send */*; format must follow the path.
    assert_equal "application/json", response.media_type
  end
end
