require "test_helper"

class AuthenticationFlowTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  # Every surface that exposes account data must require a session.
  PROTECTED = %w[/dashboard /settings /profile /strategies /strategies/new /settings/api-tokens].freeze

  test "protected pages redirect anonymous visitors to log in" do
    PROTECTED.each do |path|
      get path
      assert_redirected_to login_path, "#{path} did not require authentication"
    end
  end

  test "public pages stay public once authentication is global" do
    %w[/ /login /signup /passwords/new /offline].each do |path|
      get path
      assert_response :success, "#{path} should not require authentication"
    end
  end

  test "signing up creates a verified-pending account and starts a session" do
    assert_difference "User.count", 1 do
      post signup_path, params: { user: {
        email_address: "new@example.com", password: PASSWORD, password_confirmation: PASSWORD
      } }
    end

    assert_redirected_to dashboard_path
    user = User.find_by(email_address: "new@example.com")
    assert_not user.verified?, "a new account must start unverified"

    get dashboard_path
    assert_response :success
  end

  test "signing up sends a verification email" do
    assert_enqueued_emails 1 do
      post signup_path, params: { user: {
        email_address: "mailme@example.com", password: PASSWORD, password_confirmation: PASSWORD
      } }
    end
  end

  test "signup rejects a weak password without creating an account" do
    assert_no_difference "User.count" do
      post signup_path, params: { user: {
        email_address: "weak@example.com", password: "short", password_confirmation: "short"
      } }
    end

    assert_response :unprocessable_entity
  end

  test "logging in with correct credentials starts a session" do
    post login_path, params: { email_address: "verified@example.com", password: PASSWORD }

    assert_redirected_to dashboard_url
    get dashboard_path
    assert_response :success
  end

  test "a wrong password does not reveal whether the account exists" do
    post login_path, params: { email_address: "verified@example.com", password: "wrong-password-x" }
    wrong_password = flash[:alert]

    post login_path, params: { email_address: "nobody@example.com", password: "wrong-password-x" }
    unknown_account = flash[:alert]

    assert_equal wrong_password, unknown_account,
      "the failure message must not distinguish an unknown address from a bad password"
  end

  test "logging out ends the session and destroys the session record" do
    post login_path, params: { email_address: "verified@example.com", password: PASSWORD }

    assert_difference "Session.count", -1 do
      delete logout_path
    end

    get dashboard_path
    assert_redirected_to login_path
  end

  test "the session cookie is http-only so scripts cannot read it" do
    post login_path, params: { email_address: "verified@example.com", password: PASSWORD }

    set_cookie = response.headers["Set-Cookie"].to_s
    assert_match(/session_id/, set_cookie)
    assert_match(/httponly/i, set_cookie)
    assert_match(/samesite=lax/i, set_cookie)
  end

  test "a user is returned to the page they originally requested" do
    get settings_path
    assert_redirected_to login_path

    post login_path, params: { email_address: "verified@example.com", password: PASSWORD }
    assert_redirected_to settings_url
  end

  test "resetting a password revokes all sessions and API tokens" do
    user = users(:verified)
    user.sessions.create!(ip_address: "1.1.1.1", user_agent: "other device")
    token = ApiToken.issue(user:, name: "MT5 terminal")
    reset_token = user.generate_token_for(:password_reset)

    patch password_path, params: {
      token: reset_token,
      password: "a-brand-new-password", password_confirmation: "a-brand-new-password"
    }

    assert_equal 0, user.reload.sessions.count, "existing sessions must be revoked"
    assert_not token.reload.active?, "API tokens must be revoked so a connected client is evicted"
  end

  # The emailed link is the only way a real user reaches the reset form, so the
  # flow is driven end to end from the delivered mail rather than from a token
  # generated in the test. A helper that drops the token into :format instead of
  # the query string produces a link that always reports "invalid or expired".
  test "the link in the reset email opens the reset form" do
    perform_enqueued_jobs do
      post passwords_path, params: { email_address: users(:verified).email_address }
    end

    mail = ActionMailer::Base.deliveries.last
    assert_not_nil mail, "a reset email should have been delivered"

    link = mail.body.encoded[%r{https?://\S*/passwords/edit\S*}]
    assert_not_nil link, "the reset email should contain a link to the reset form"

    get link
    assert_response :success
    assert_select %(input[name="token"]) do |inputs|
      assert inputs.first["value"].present?, "the reset form should carry the token"
    end
  end

  test "password reset does not disclose whether an address is registered" do
    post passwords_path, params: { email_address: "nobody@example.com" }
    unknown = flash[:notice]

    post passwords_path, params: { email_address: "verified@example.com" }
    known = flash[:notice]

    assert_equal unknown, known
  end
end
