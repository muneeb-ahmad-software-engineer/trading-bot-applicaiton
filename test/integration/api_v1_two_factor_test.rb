require "test_helper"

# Two-factor on the API.
#
# The point of these tests is that the API must not become a way around the
# second factor: an attacker with a password must not be able to obtain a
# trading-capable token just by using the mobile endpoint instead of the browser.
class ApiV1TwoFactorTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  setup do
    @user = users(:verified)
    @user.prepare_otp_secret!
    @user.enable_otp!
  end

  def code = ROTP::TOTP.new(@user.reload.otp_secret).now

  def login(**params)
    post "/api/v1/auth/login",
         params: { email_address: @user.email_address, password: PASSWORD }.merge(params),
         as: :json
  end

  def json = JSON.parse(response.body)

  test "a password alone does not yield a token" do
    assert_no_difference "ApiToken.count" do
      login
    end

    assert_response :unauthorized
    assert_equal "otp_required", json.dig("error", "code")
  end

  test "the error tells a client to prompt for a code" do
    login

    # A client needs a distinguishable code so it can show an OTP prompt rather
    # than "wrong password".
    assert_equal "otp_required", json.dig("error", "code")
    assert_no_match(/password/i, json.dig("error", "message"))
  end

  test "a wrong code does not yield a token" do
    assert_no_difference "ApiToken.count" do
      login(otp_code: "000000")
    end

    assert_response :unauthorized
    assert_equal "invalid_otp", json.dig("error", "code")
  end

  test "a valid code yields a working token" do
    assert_difference "ApiToken.count", 1 do
      login(otp_code: code)
    end

    assert_response :created
    assert_equal true, json.dig("user", "two_factor_enabled")

    get "/api/v1/profile", headers: { "Authorization" => "Bearer #{json['token']}" }
    assert_response :success
  end

  test "an API code cannot be replayed" do
    used = code
    login(otp_code: used)
    assert_response :created

    login(otp_code: used)

    assert_response :unauthorized
    assert_equal "invalid_otp", json.dig("error", "code")
  end

  test "a recovery code works over the API and is then spent" do
    codes = RecoveryCode.regenerate_for(@user)

    login(otp_code: codes.first)
    assert_response :created

    login(otp_code: codes.first)
    assert_response :unauthorized
  end

  test "an account without two-factor is unaffected" do
    other = users(:unverified)

    post "/api/v1/auth/login",
         params: { email_address: other.email_address, password: PASSWORD }, as: :json

    assert_response :created
    assert_equal false, json.dig("user", "two_factor_enabled")
  end

  test "a wrong password is refused before any code is considered" do
    post "/api/v1/auth/login",
         params: { email_address: @user.email_address, password: "wrong-password-x", otp_code: code },
         as: :json

    assert_response :unauthorized
    assert_equal "invalid_credentials", json.dig("error", "code")
  end

  test "profile reports two-factor state so a client can prompt to enable it" do
    login(otp_code: code)
    token = json["token"]

    get "/api/v1/profile", headers: { "Authorization" => "Bearer #{token}" }

    assert_equal true, json["two_factor_enabled"]
  end
end
