require "test_helper"

# The page that makes multi-user trading reachable at all: until a user can
# enter a broker account through the interface, the execution manager has
# nothing to sign in with and no terminal can be started for anybody.
class BrokerCredentialsTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  DETAILS = { server: "ExampleBroker-Demo", login: "500123", password: "broker-trading-password", demo: "true" }.freeze

  setup do
    @user = users(:verified)
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
  end

  test "a user can save broker details and they are stored encrypted" do
    patch broker_credential_path, params: { broker_credential: DETAILS }

    assert_redirected_to edit_broker_credential_path
    credential = @user.reload.broker_credential
    assert_equal "ExampleBroker-Demo", credential.server
    assert_equal "broker-trading-password", credential.password

    stored = BrokerCredential.connection.select_value(
      "SELECT password FROM broker_credentials WHERE id = #{credential.id}"
    )
    assert_not_equal "broker-trading-password", stored,
      "a database dump must not hand over a trading account"
  end

  test "saving broker details is audited without the password" do
    patch broker_credential_path, params: { broker_credential: DETAILS }

    event = @user.events.where(action: "broker_credential.saved").sole
    assert_not_includes event.metadata.to_json, "broker-trading-password"
  end

  test "the password is kept when the field is left blank" do
    patch broker_credential_path, params: { broker_credential: DETAILS }
    patch broker_credential_path, params: { broker_credential: DETAILS.merge(server: "Other-Demo", password: "") }

    credential = @user.reload.broker_credential
    assert_equal "Other-Demo", credential.server
    assert_equal "broker-trading-password", credential.password,
      "correcting a server name must not require retyping a password the form cannot show"
  end

  test "invalid details are rejected rather than half-saved" do
    patch broker_credential_path, params: { broker_credential: DETAILS.merge(server: "") }

    assert_response :unprocessable_entity
    assert_nil @user.reload.broker_credential
  end

  test "the page is reachable and names the account once saved" do
    patch broker_credential_path, params: { broker_credential: DETAILS }
    get edit_broker_credential_path

    assert_response :success
    assert_match "ExampleBroker-Demo", response.body
  end

  test "the broker password is never rendered back to the browser" do
    patch broker_credential_path, params: { broker_credential: DETAILS }
    get edit_broker_credential_path

    assert_no_match(/broker-trading-password/, response.body)
  end

  test "the page never nests one form inside another" do
    patch broker_credential_path, params: { broker_credential: DETAILS }
    get edit_broker_credential_path

    # Browsers drop a nested <form> tag, so a Remove button placed inside the
    # save form would silently submit the save instead of deleting anything.
    assert_empty Nokogiri::HTML(response.body).css("form form")
  end

  test "the Remove button is a delete form that asks for confirmation" do
    patch broker_credential_path, params: { broker_credential: DETAILS }
    get edit_broker_credential_path

    remove = Nokogiri::HTML(response.body).at_css("form[action='#{broker_credential_path}'][data-turbo-confirm]")
    assert_equal "delete", remove.at_css("input[name='_method']")["value"]
  end

  test "saving without a recent password entry says the details were not kept" do
    travel Authentication::REAUTHENTICATION_WINDOW + 1.minute

    patch broker_credential_path, params: { broker_credential: DETAILS }

    assert_redirected_to new_reauthentication_path
    assert_match "enter them again", flash[:alert]
    assert_equal edit_broker_credential_path, session[:return_to_after_reauthentication]
  end

  test "settings links to the broker account page" do
    get settings_path

    assert_response :success
    assert_match edit_broker_credential_path, response.body
  end

  # ------------------------------------------------------------------ Guards

  test "saving broker details requires a recent password entry" do
    get logout_path # no-op for the guard, but clears sudo mode below
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
    travel Authentication::REAUTHENTICATION_WINDOW + 1.minute

    patch broker_credential_path, params: { broker_credential: DETAILS }

    assert_redirected_to new_reauthentication_path
    assert_nil @user.reload.broker_credential
  end

  test "an unverified user cannot store broker details" do
    delete logout_path
    user = users(:unverified)
    post login_path, params: { email_address: user.email_address, password: PASSWORD }

    patch broker_credential_path, params: { broker_credential: DETAILS }

    assert_redirected_to dashboard_path
    assert_nil user.reload.broker_credential
  end

  test "one user cannot see or overwrite another's broker details" do
    patch broker_credential_path, params: { broker_credential: DETAILS }

    delete logout_path
    other = User.create!(email_address: "other@example.com", password: PASSWORD, verified_at: Time.current)
    post login_path, params: { email_address: other.email_address, password: PASSWORD }

    get edit_broker_credential_path
    assert_no_match(/ExampleBroker-Demo/, response.body)

    patch broker_credential_path, params: { broker_credential: DETAILS.merge(server: "Hijacked") }
    assert_equal "ExampleBroker-Demo", @user.reload.broker_credential.server
    assert_equal "Hijacked", other.reload.broker_credential.server
  end

  # ----------------------------------------------------------------- Removal

  test "removing broker details shuts the terminal down and deletes its directory" do
    with_mt5_sandbox do
      worker_node
      patch broker_credential_path, params: { broker_credential: DETAILS }
      instance = running_instance(@user)

      delete broker_credential_path

      assert_nil @user.reload.broker_credential
      assert_predicate instance.reload, :terminated?
      assert_not File.exist?(instance.instance_dir),
        "a terminal directory holds a copy of the password being removed"
    end
  end

  test "removal does not require a recent password entry" do
    patch broker_credential_path, params: { broker_credential: DETAILS }
    travel Authentication::REAUTHENTICATION_WINDOW + 1.minute

    delete broker_credential_path

    assert_nil @user.reload.broker_credential,
      "a user who believes their credentials are compromised must be able to pull them immediately"
  end
end
