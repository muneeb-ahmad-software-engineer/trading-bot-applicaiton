require "test_helper"

class EmailVerificationTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  def login_as(user)
    post login_path, params: { email_address: user.email_address, password: PASSWORD }
  end

  test "a valid link verifies the address" do
    user = users(:unverified)
    get verify_email_path(token: user.generate_token_for(:email_verification))

    assert_predicate user.reload, :verified?
    assert_redirected_to dashboard_path
  end

  test "an invalid or expired link verifies nothing" do
    get verify_email_path(token: "not-a-real-token")

    assert_redirected_to root_path
    assert_not users(:unverified).reload.verified?
  end

  test "verification works without being logged in" do
    # The link is opened from an email client, which carries no session cookie.
    user = users(:unverified)
    get verify_email_path(token: user.generate_token_for(:email_verification))

    assert_predicate user.reload, :verified?
  end

  test "an unverified user can still browse and draft" do
    login_as users(:unverified)

    %w[/dashboard /strategies /settings /profile].each do |path|
      get path
      assert_response :success, "#{path} should be reachable before verification"
    end
  end

  test "an unverified user cannot issue an API token" do
    login_as users(:unverified)

    assert_no_difference "ApiToken.count" do
      post api_tokens_path, params: { api_token: { name: "MT5 terminal" } }
    end

    assert_redirected_to dashboard_path
  end

  test "a verified user can issue an API token" do
    login_as users(:verified)

    assert_difference "ApiToken.count", 1 do
      post api_tokens_path, params: { api_token: { name: "MT5 terminal" } }
    end
  end

  test "an unverified user can still revoke a token they already hold" do
    user = users(:unverified)
    token = ApiToken.issue(user:, name: "old client")
    login_as user

    delete api_token_path(token)

    assert_not token.reload.active?, "revoking access must never be blocked"
  end

  test "a user cannot revoke another user's token" do
    victim_token = ApiToken.issue(user: users(:unverified), name: "victim MT5")
    login_as users(:verified)

    delete api_token_path(victim_token)

    assert_response :not_found
    assert_predicate victim_token.reload, :active?
  end
end
