require "test_helper"

# The versioned API consumed by the MT5 Expert Advisor and future mobile apps.
class ApiV1Test < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  def auth_headers(token) = { "Authorization" => "Bearer #{token}" }

  test "status is public and reports the API version" do
    get "/api/v1/status"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "v1", body["api_version"]
    assert_equal "ok", body["status"]
  end

  test "status exposes no account data" do
    get "/api/v1/status"

    assert_not_includes response.body, "@example.com"
  end

  test "protected endpoints reject a missing, malformed or unknown token" do
    [ nil, { "Authorization" => "Bearer" }, { "Authorization" => "Basic abc" },
      { "Authorization" => "Bearer ggk_nope" } ].each do |headers|
      get "/api/v1/profile", headers: headers

      assert_response :unauthorized
      assert_equal "unauthorized", JSON.parse(response.body).dig("error", "code")
    end
  end

  test "unauthorized responses advertise the bearer scheme" do
    get "/api/v1/profile"

    assert_match(/Bearer/, response.headers["WWW-Authenticate"].to_s)
  end

  test "login exchanges credentials for a bearer token" do
    post "/api/v1/auth/login", params: {
      email_address: "verified@example.com", password: PASSWORD, device_name: "iPhone"
    }, as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert body["token"].start_with?(ApiToken::PREFIX)
    assert_equal true, body.dig("user", "may_trade")

    # The issued token actually works.
    get "/api/v1/profile", headers: auth_headers(body["token"])
    assert_response :success
  end

  test "login with bad credentials gives one indistinguishable error" do
    post "/api/v1/auth/login", params: { email_address: "verified@example.com", password: "wrong-password" }, as: :json
    wrong = response.body
    assert_response :unauthorized

    post "/api/v1/auth/login", params: { email_address: "nobody@example.com", password: "wrong-password" }, as: :json
    unknown = response.body

    assert_equal wrong, unknown, "the API must not let a client enumerate accounts"
  end

  test "an unverified user can authenticate but is flagged as unable to trade" do
    post "/api/v1/auth/login", params: {
      email_address: "unverified@example.com", password: PASSWORD
    }, as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal false, body.dig("user", "verified")
    assert_equal false, body.dig("user", "may_trade"),
      "the client needs to know trading actions will be refused before it tries one"
  end

  test "logout revokes the presented token immediately" do
    token = ApiToken.issue(user: users(:verified), name: "iPhone")

    delete "/api/v1/auth/logout", headers: auth_headers(token.plaintext_token)
    assert_response :no_content

    get "/api/v1/profile", headers: auth_headers(token.plaintext_token)
    assert_response :unauthorized
  end

  test "a token only ever grants access to its own owner's data" do
    token = ApiToken.issue(user: users(:unverified), name: "iPhone")

    get "/api/v1/profile", headers: auth_headers(token.plaintext_token)

    assert_equal users(:unverified).email_address, JSON.parse(response.body)["email_address"]
  end

  test "API responses set no session cookie" do
    token = ApiToken.issue(user: users(:verified), name: "iPhone")

    get "/api/v1/profile", headers: auth_headers(token.plaintext_token)

    assert_nil response.headers["Set-Cookie"]
  end

  test "using a token records that the client called in" do
    token = ApiToken.issue(user: users(:verified), name: "MT5 terminal")

    get "/api/v1/profile", headers: auth_headers(token.plaintext_token)

    assert_not_nil token.reload.last_used_at
  end
end
