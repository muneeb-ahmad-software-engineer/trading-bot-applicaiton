require "test_helper"

class ApiTokenTest < ActiveSupport::TestCase
  setup { @user = users(:verified) }

  test "issuing returns the plaintext once and stores only a digest" do
    token = ApiToken.issue(user: @user, name: "MT5 terminal")

    assert token.plaintext_token.start_with?(ApiToken::PREFIX)
    # The plaintext must not be recoverable from the database.
    assert_not_equal token.plaintext_token, token.token_digest
    assert_nil ApiToken.find(token.id).plaintext_token
    assert_not ApiToken.where(token_digest: token.plaintext_token).exists?
  end

  test "authenticates a valid token and rejects anything else" do
    token = ApiToken.issue(user: @user, name: "MT5")

    assert_equal token, ApiToken.authenticate(token.plaintext_token)
    assert_nil ApiToken.authenticate("ggk_wrong")
    assert_nil ApiToken.authenticate(nil)
    assert_nil ApiToken.authenticate("")
  end

  test "a revoked token stops authenticating immediately" do
    token = ApiToken.issue(user: @user, name: "MT5")
    plaintext = token.plaintext_token

    token.revoke!

    assert_nil ApiToken.authenticate(plaintext)
    assert_not token.active?
  end

  test "an expired token stops authenticating" do
    token = ApiToken.issue(user: @user, name: "MT5", expires_at: 1.hour.ago)

    assert_nil ApiToken.authenticate(token.plaintext_token)
  end

  test "tokens are unpredictable and unique" do
    tokens = 20.times.map { ApiToken.issue(user: @user, name: "t").plaintext_token }

    assert_equal 20, tokens.uniq.size
    # 32 random bytes, base64url encoded.
    assert tokens.first.delete_prefix(ApiToken::PREFIX).length >= 43
  end

  test "last_used_at is throttled to avoid a write per request" do
    token = ApiToken.issue(user: @user, name: "MT5")

    token.touch_last_used!
    first = token.reload.last_used_at
    assert_not_nil first

    token.touch_last_used!
    assert_equal first.to_i, token.reload.last_used_at.to_i, "a second call within the hour should not write"
  end

  test "display hint identifies a token without revealing it" do
    token = ApiToken.issue(user: @user, name: "MT5")

    assert_not_includes token.display_hint, token.plaintext_token
  end
end
