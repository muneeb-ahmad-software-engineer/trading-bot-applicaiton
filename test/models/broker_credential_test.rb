require "test_helper"

# Whether a broker login works is not something this application can ask. It
# never talks to a broker — only a terminal does. So "verified" here means a
# terminal signed in with these details and reported back, and these tests are
# mostly about not claiming more than that.
class BrokerCredentialTest < ActiveSupport::TestCase
  setup do
    @user = users(:verified)
  end

  def credential(**overrides)
    BrokerCredential.new({ user: @user, server: "ExampleBroker-Demo", login: "500123",
                           password: "trading-password", demo: true }.merge(overrides))
  end

  test "an account number that MetaTrader cannot use is rejected at the form" do
    assert_not credential(login: "trader@example.com").valid?,
      "a portal email pasted into the account field must not become a three-minute connect timeout"
    assert_not credential(login: "user_name").valid?
    assert credential(login: "500123").valid?
  end

  test "a new credential has never been verified" do
    record = credential
    record.save!

    assert_not_predicate record, :verified?
    assert_nil record.last_verification_error
  end

  test "a terminal reporting in is what verifies the details" do
    record = credential
    record.save!

    record.record_verification!

    assert_predicate record.reload, :verified?
  end

  test "verification is not rewritten on every report" do
    record = credential
    record.save!
    record.record_verification!
    first = record.reload.last_verified_at

    record.record_verification!

    assert_equal first, record.reload.last_verified_at,
      "reports arrive every ten seconds and must not each cost a write"
  end

  test "a failure to connect is recorded against the credential, not just the terminal" do
    record = credential
    record.save!
    record.record_verification!

    record.record_verification_failure!("Never reported back.")

    assert_equal "Never reported back.", record.reload.last_verification_error
  end

  test "editing the details withdraws the verification they were given" do
    record = credential
    record.save!
    record.record_verification!

    record.update!(password: "a-different-password")

    assert_not_predicate record.reload, :verified?,
      "a tick beside a password nothing has signed in with is worse than no tick"
  end

  test "editing something that is not a credential leaves the verification alone" do
    record = credential
    record.save!
    record.record_verification!

    record.update!(demo: false)

    assert_predicate record.reload, :verified?
  end

  test "a password is never written into a log line or an inspect" do
    record = credential
    record.save!

    assert_not_includes record.inspect, "trading-password"
    assert_not_includes record.to_log.to_json, "trading-password"
  end
end
