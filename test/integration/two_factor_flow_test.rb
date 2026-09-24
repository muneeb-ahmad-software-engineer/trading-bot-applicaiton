require "test_helper"

class TwoFactorFlowTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  setup do
    @user = users(:verified)
    @user.prepare_otp_secret!
    @user.enable_otp!
  end

  def code = ROTP::TOTP.new(@user.reload.otp_secret).now

  def submit_password
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
  end

  # ------------------------------------------------ The central guarantee

  test "a correct password alone does not create a session" do
    assert_no_difference "Session.count" do
      submit_password
    end

    assert_redirected_to new_two_factor_challenge_path

    # And it does not grant access to anything.
    get dashboard_path
    assert_redirected_to login_path
  end

  test "completing the challenge creates the session" do
    submit_password

    assert_difference "Session.count", 1 do
      post login_two_factor_path, params: { code: }
    end

    get dashboard_path
    assert_response :success
  end

  test "a wrong code does not create a session" do
    submit_password

    assert_no_difference "Session.count" do
      post login_two_factor_path, params: { code: "000000" }
    end

    assert_response :unprocessable_entity
    get dashboard_path
    assert_redirected_to login_path
  end

  test "the challenge cannot be reached without first passing the password" do
    get new_two_factor_challenge_path
    assert_redirected_to login_path

    post login_two_factor_path, params: { code: }
    assert_redirected_to login_path
    assert_equal 0, Session.count
  end

  test "a pending challenge expires" do
    submit_password

    travel (Authentication::PENDING_AUTH_WINDOW + 1.minute) do
      post login_two_factor_path, params: { code: }

      assert_redirected_to login_path
      assert_equal 0, Session.count
    end
  end

  test "a used code cannot be replayed to open a second session" do
    submit_password
    used = code
    post login_two_factor_path, params: { code: used }
    assert_equal 1, Session.count

    delete logout_path
    submit_password
    post login_two_factor_path, params: { code: used }

    assert_response :unprocessable_entity
    assert_equal 0, Session.count
  end

  test "a recovery code completes the challenge and is then spent" do
    codes = RecoveryCode.regenerate_for(@user)
    submit_password

    post login_two_factor_path, params: { code: codes.first }
    assert_response :redirect
    get dashboard_path
    assert_response :success

    delete logout_path
    submit_password
    post login_two_factor_path, params: { code: codes.first }
    assert_response :unprocessable_entity
  end

  test "an account without two-factor logs in normally" do
    other = users(:unverified)

    assert_difference "Session.count", 1 do
      post login_path, params: { email_address: other.email_address, password: PASSWORD }
    end
  end

  # ------------------------------------------------------------ Enrolment

  test "enrolment requires a working code before it switches on" do
    user = users(:unverified)
    post login_path, params: { email_address: user.email_address, password: PASSWORD }

    get new_two_factor_settings_path
    assert_response :success
    assert user.reload.otp_secret.present?
    assert_not user.otp_enabled?

    post two_factor_settings_path, params: { code: "000000" }
    assert_response :unprocessable_entity
    assert_not user.reload.otp_enabled?, "a bad code must not enable 2FA"

    post two_factor_settings_path, params: { code: ROTP::TOTP.new(user.reload.otp_secret).now }
    assert_predicate user.reload, :otp_enabled?
  end

  # Turbo ignores a 200 HTML response to a form POST: the browser stays put and
  # the user sees nothing happen, even though the server did the work. Every
  # successful form POST must therefore redirect. This caught a real bug where
  # enabling 2FA appeared to do nothing in the browser.
  test "successful form posts redirect rather than rendering" do
    user = users(:unverified)
    post login_path, params: { email_address: user.email_address, password: PASSWORD }
    get new_two_factor_settings_path

    post two_factor_settings_path, params: { code: ROTP::TOTP.new(user.reload.otp_secret).now }
    assert_response :redirect, "enabling 2FA must redirect, or Turbo drops the response"

    follow_redirect!
    assert_response :success
    assert_match(/recovery code/i, response.body)

    post recovery_codes_path
    assert_response :redirect, "regenerating codes must redirect, or Turbo drops the response"
  end

  test "recovery codes are not shown on a direct visit" do
    user = users(:unverified)
    post login_path, params: { email_address: user.email_address, password: PASSWORD }

    get recovery_codes_path

    # They exist only as digests; there is nothing to show without the flash.
    assert_redirected_to settings_path
  end

  test "enrolment issues recovery codes exactly once" do
    user = users(:unverified)
    post login_path, params: { email_address: user.email_address, password: PASSWORD }
    get new_two_factor_settings_path
    post two_factor_settings_path, params: { code: ROTP::TOTP.new(user.reload.otp_secret).now }
    follow_redirect!

    assert_response :success
    assert_equal RecoveryCode::BATCH_SIZE, user.recovery_codes.count
    assert_match(/recovery codes/i, response.body)
  end

  # ----------------------------------------------------------- Sudo mode

  def sign_in_fully
    submit_password
    post login_two_factor_path, params: { code: }
  end

  test "issuing an API token requires recent authentication" do
    sign_in_fully

    travel (Authentication::REAUTHENTICATION_WINDOW + 1.minute) do
      assert_no_difference "ApiToken.count" do
        post api_tokens_path, params: { api_token: { name: "MT5" } }
      end

      assert_redirected_to new_reauthentication_path
    end
  end

  test "disabling two-factor requires recent authentication" do
    sign_in_fully

    travel (Authentication::REAUTHENTICATION_WINDOW + 1.minute) do
      delete settings_two_factor_path

      assert_redirected_to new_reauthentication_path
      assert_predicate @user.reload, :otp_enabled?, "2FA must not be removed without re-authentication"
    end
  end

  test "sudo mode also demands the second factor, not just the password" do
    sign_in_fully

    travel (Authentication::REAUTHENTICATION_WINDOW + 1.minute) do
      # Password alone must not reopen sudo mode on a 2FA account.
      post reauthentications_path, params: { password: PASSWORD }
      assert_response :unprocessable_entity

      delete settings_two_factor_path
      assert_redirected_to new_reauthentication_path
      assert_predicate @user.reload, :otp_enabled?
    end
  end

  test "re-authenticating reopens sudo mode" do
    sign_in_fully

    travel (Authentication::REAUTHENTICATION_WINDOW + 1.minute) do
      post reauthentications_path, params: { password: PASSWORD, code: }
      assert_response :redirect

      delete settings_two_factor_path
      assert_not @user.reload.otp_enabled?
    end
  end

  test "a wrong password does not open sudo mode" do
    sign_in_fully

    travel (Authentication::REAUTHENTICATION_WINDOW + 1.minute) do
      post reauthentications_path, params: { password: "wrong-password-xx", code: }
      assert_response :unprocessable_entity
    end
  end
end
