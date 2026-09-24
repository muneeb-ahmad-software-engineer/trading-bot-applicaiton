require "test_helper"

class ApiTokensTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  setup do
    @user = users(:verified)
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
  end

  test "a newly issued token is rendered with a copy control" do
    post api_tokens_path, params: { api_token: { name: "MT5 terminal" } }
    follow_redirect!

    assert_select "[data-controller=clipboard]" do
      assert_select "[data-clipboard-target=source]", text: /\Aggk_/
      assert_select "[data-action='clipboard#copy']"
    end
  end

  test "regenerating revokes the old token and issues a replacement under the same name" do
    old = ApiToken.issue(user: @user, name: "MT5 terminal")

    assert_difference "@user.api_tokens.count", 1 do
      post regenerate_api_token_path(old)
    end

    assert_not old.reload.active?, "the token being replaced must stop working"

    issued = @user.api_tokens.order(:created_at).last
    assert_equal "MT5 terminal", issued.name
    assert_predicate issued, :active?
    assert_nil issued.plaintext_token, "the plaintext is never reloaded from the database"
    assert_match(/\Aggk_/, flash[:new_token])
  end

  test "a revoked token can be regenerated" do
    revoked = ApiToken.issue(user: @user, name: "Old laptop")
    revoked.revoke!

    assert_difference "@user.api_tokens.active.count", 1 do
      post regenerate_api_token_path(revoked)
    end

    assert_equal "Old laptop", @user.api_tokens.active.last.name
  end

  test "regenerating another user's token is not possible" do
    other = ApiToken.issue(user: users(:unverified), name: "Not yours")

    assert_no_difference "ApiToken.count" do
      post regenerate_api_token_path(other)
    end
    assert_predicate other.reload, :active?
  end

  test "a revoked token can be deleted" do
    token = ApiToken.issue(user: @user, name: "Old laptop")
    token.revoke!

    assert_difference "ApiToken.count", -1 do
      delete purge_api_token_path(token)
    end

    assert_redirected_to api_tokens_path
    assert_nil ApiToken.find_by(id: token.id)
  end

  test "an active token cannot be deleted before it is revoked" do
    token = ApiToken.issue(user: @user, name: "MT5 terminal")

    assert_no_difference "ApiToken.count" do
      delete purge_api_token_path(token)
    end

    assert_predicate token.reload, :active?
    assert_match(/revoke/i, flash[:alert])
  end

  test "deleting another user's token is not possible" do
    other = ApiToken.issue(user: users(:unverified), name: "Not yours")
    other.revoke!

    assert_no_difference "ApiToken.count" do
      delete purge_api_token_path(other)
    end
  end

  test "deleting a token keeps the audit trail that mentions it" do
    post api_tokens_path, params: { api_token: { name: "MT5 terminal" } }
    token = @user.api_tokens.order(:created_at).last
    delete api_token_path(token)
    delete purge_api_token_path(token)

    actions = @user.events.reload.pluck(:action)
    assert_includes actions, "api_token.issued"
    assert_includes actions, "api_token.deleted"
    assert_includes @user.events.map(&:description), "Deleted API token MT5 terminal"
  end
end
