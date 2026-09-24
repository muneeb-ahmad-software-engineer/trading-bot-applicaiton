require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "email addresses are normalised and must be unique" do
    User.create!(email_address: "  Trader@Example.COM ", password: "a-long-test-password")

    assert User.exists?(email_address: "trader@example.com")

    duplicate = User.new(email_address: "TRADER@example.com", password: "a-long-test-password")
    assert_not duplicate.valid?
  end

  test "rejects a malformed email address" do
    user = User.new(email_address: "not-an-email", password: "a-long-test-password")

    assert_not user.valid?
    assert_includes user.errors[:email_address], "must be a valid email address"
  end

  test "requires a password of at least 12 characters" do
    user = User.new(email_address: "short@example.com", password: "tooshort")

    assert_not user.valid?
    assert_predicate user.errors[:password], :any?
  end

  test "authenticate_by rejects a wrong password" do
    assert_nil User.authenticate_by(email_address: "verified@example.com", password: "wrong-password-here")
    assert_equal users(:verified),
                 User.authenticate_by(email_address: "verified@example.com", password: "a-long-test-password")
  end

  test "only a verified user may trade" do
    assert_predicate users(:verified), :may_trade?
    assert_not users(:unverified).may_trade?
  end

  test "verify! records when verification happened" do
    user = users(:unverified)

    assert_not user.verified?
    user.verify!

    assert_predicate user.reload, :verified?
    assert_not_nil user.verified_at
  end

  test "a password reset token stops working once the password changes" do
    user = users(:verified)
    token = user.generate_token_for(:password_reset)

    assert_equal user, User.find_by_token_for(:password_reset, token)

    user.update!(password: "a-different-long-password")

    # The token is bound to the password salt, so a used reset link cannot be
    # replayed to take the account over a second time.
    assert_nil User.find_by_token_for(:password_reset, token)
  end

  test "an email verification token stops working if the address changes" do
    user = users(:unverified)
    token = user.generate_token_for(:email_verification)

    user.update!(email_address: "moved@example.com")

    assert_nil User.find_by_token_for(:email_verification, token)
  end

  test "deleting a user removes their sessions and tokens" do
    user = users(:verified)
    user.sessions.create!(ip_address: "127.0.0.1", user_agent: "test")
    ApiToken.issue(user:, name: "MT5")

    assert_difference [ "Session.count", "ApiToken.count" ], -1 do
      user.destroy
    end
  end
end
