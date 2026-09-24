require "test_helper"

class TwoFactorTest < ActiveSupport::TestCase
  setup do
    @user = users(:verified)
    @user.prepare_otp_secret!
  end

  def current_code = ROTP::TOTP.new(@user.otp_secret).now

  test "a prepared secret is not yet enabled" do
    assert @user.otp_secret.present?
    assert_not @user.otp_enabled?, "generating a secret must not switch 2FA on — that would lock the user out"
  end

  test "the secret is encrypted at rest" do
    raw = User.connection.select_value("select otp_secret from users where id = #{@user.id}")

    assert_not_equal @user.otp_secret, raw
    assert_no_match(/#{Regexp.escape(@user.otp_secret)}/, raw.to_s)
  end

  test "a valid code verifies and an invalid one does not" do
    assert @user.verify_otp(current_code)
    assert_not @user.verify_otp("000000")
    assert_not @user.verify_otp("")
    assert_not @user.verify_otp(nil)
  end

  test "a code cannot be replayed within its window" do
    code = current_code

    assert @user.verify_otp(code)
    assert_not @user.verify_otp(code),
      "a one-time password must be single-use, or an observed code stays valid for 30 seconds"
  end

  test "an earlier time step cannot be replayed after a later one" do
    totp = ROTP::TOTP.new(@user.otp_secret)
    older = totp.at(Time.current - 30)

    assert @user.verify_otp(totp.now)
    assert_not @user.verify_otp(older), "stepping backwards must be refused"
  end

  test "codes are rejected outright when no secret exists" do
    @user.update!(otp_secret: nil)

    assert_not @user.verify_otp("123456")
  end

  test "disabling clears the secret and voids recovery codes" do
    @user.enable_otp!
    RecoveryCode.regenerate_for(@user)

    @user.disable_otp!

    assert_not @user.otp_enabled?
    assert_nil @user.otp_secret
    assert_nil @user.otp_last_used_step
    assert_equal 0, @user.recovery_codes.count
  end

  test "provisioning uri carries the issuer and account" do
    uri = @user.otp_provisioning_uri

    assert_match(/^otpauth:\/\/totp\//, uri)
    assert_match(/issuer=GoldGrid/, uri)
    assert_match(/verified%40example.com/, uri)
  end
end

class RecoveryCodeTest < ActiveSupport::TestCase
  setup { @user = users(:verified) }

  test "regenerating issues a fixed batch and stores only digests" do
    codes = RecoveryCode.regenerate_for(@user)

    assert_equal RecoveryCode::BATCH_SIZE, codes.size
    assert_equal RecoveryCode::BATCH_SIZE, @user.recovery_codes.count

    stored = @user.recovery_codes.pluck(:code_digest)
    codes.each { |code| assert_not_includes stored, code }
  end

  test "a code works once and only once" do
    code = RecoveryCode.regenerate_for(@user).first

    assert RecoveryCode.consume(user: @user, code:)
    assert_not RecoveryCode.consume(user: @user, code:), "a recovery code must be single-use"
  end

  test "codes are accepted regardless of spacing and case" do
    code = RecoveryCode.regenerate_for(@user).first

    assert RecoveryCode.consume(user: @user, code: code.downcase.gsub("-", " "))
  end

  test "one user's code does not work for another" do
    code = RecoveryCode.regenerate_for(@user).first

    assert_not RecoveryCode.consume(user: users(:unverified), code:)
  end

  test "regenerating invalidates the previous set" do
    old = RecoveryCode.regenerate_for(@user).first
    RecoveryCode.regenerate_for(@user)

    assert_not RecoveryCode.consume(user: @user, code: old)
  end

  test "garbage is rejected" do
    RecoveryCode.regenerate_for(@user)

    assert_not RecoveryCode.consume(user: @user, code: "")
    assert_not RecoveryCode.consume(user: @user, code: nil)
    assert_not RecoveryCode.consume(user: @user, code: "NOTAREALCODE")
  end

  test "a recovery code satisfies the second factor" do
    @user.prepare_otp_secret!
    @user.enable_otp!
    code = RecoveryCode.regenerate_for(@user).first

    assert @user.verify_second_factor(code)
    assert_not @user.verify_second_factor(code)
  end
end
