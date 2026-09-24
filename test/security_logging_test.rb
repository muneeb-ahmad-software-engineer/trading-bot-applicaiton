require "test_helper"

# What may reach a log file.
#
# Logs are routinely shipped to third-party aggregators and retained for months.
# A credential written there in plaintext is a credential held by everyone with
# log access, for as long as the retention window.
class SecurityLoggingTest < ActiveSupport::TestCase
  SENSITIVE = {
    "password" => "hunter2-hunter2",
    "otp_code" => "123456",
    "code" => "ABCDE-FGHIJ",              # two-factor and recovery codes
    "token" => "eyJfcmFpbHMiOnsiZGF0YSI6",
    "auth_key" => "push-auth-secret",
    "p256dh_key" => "push-key-secret",
    "endpoint" => "https://fcm.example/secret-device-id"
  }.freeze

  test "every sensitive parameter this application accepts is filtered" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    SENSITIVE.each do |key, value|
      filtered = filter.filter(key => value)

      assert_equal "[FILTERED]", filtered[key],
        "#{key} would be written to the log in plaintext"
    end
  end

  # filter_parameters redacts query strings but cannot redact a path segment,
  # so a single-use credential must never be routed as one.
  test "no route carries a credential as a path segment" do
    offenders = Rails.application.routes.routes.filter_map do |route|
      spec = route.path.spec.to_s
      spec if spec.match?(/:(token|code|otp|secret|password)\b/)
    end

    assert_empty offenders,
      "these routes put a credential in the URL path, where logs record it verbatim:\n" +
      offenders.join("\n")
  end

  test "the reset and verification links use parameters, not path segments" do
    assert_equal "/passwords/edit", Rails.application.routes.url_helpers.edit_password_path.split("?").first
    assert_equal "/verify", Rails.application.routes.url_helpers.verify_email_path.split("?").first
  end
end
