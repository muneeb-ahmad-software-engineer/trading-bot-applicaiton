require "test_helper"

class NotificationsDeliveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup { @user = users(:verified) }

  def deliver(dedup_key: "terminal_stale:1", alert_type: "terminal_stale", **overrides)
    Notifications::Deliver.call(
      user: @user, alert_type:, dedup_key:,
      body: "Something happened.", **overrides
    )
  end

  test "creates a notification and emails it" do
    assert_enqueued_emails 1 do
      result = deliver
      assert_predicate result, :success?
    end

    notification = @user.notifications.sole
    assert_not_nil notification.emailed_at
  end

  test "an unresolved situation is not delivered twice" do
    deliver

    assert_no_difference "Notification.count" do
      assert_no_enqueued_emails { deliver }
    end
  end

  test "the same key delivers again once the situation is resolved" do
    deliver
    @user.notifications.sole.resolve!

    assert_difference "Notification.count", 1 do
      deliver
    end
  end

  test "different situations are delivered independently" do
    deliver(dedup_key: "terminal_stale:1")
    deliver(dedup_key: "terminal_stale:2")

    assert_equal 2, @user.notifications.count
  end

  test "a disabled channel is not used" do
    @user.notification_preferences_object.update("margin_low" => { "email" => "0", "push" => "0" })

    assert_no_enqueued_emails do
      deliver(alert_type: "margin_low", dedup_key: "margin_low:1")
    end

    assert_nil @user.notifications.sole.emailed_at
  end

  test "a mandatory alert cannot be switched off" do
    @user.notification_preferences_object.update("terminal_stale" => { "email" => "0", "push" => "0" })

    # A running strategy with a silent terminal must always reach the user.
    assert_enqueued_emails 1 do
      deliver
    end

    assert @user.notification_preferences_object.enabled?("terminal_stale", "email")
  end

  test "an unknown alert type is refused" do
    result = deliver(alert_type: "not_a_real_alert", dedup_key: "x")

    assert_predicate result, :failure?
    assert_equal "unknown_alert_type", result.error_code
  end

  test "push is skipped when the user has no devices" do
    assert_no_enqueued_jobs only: DeliverPushNotificationJob do
      deliver
    end
  end

  test "push is enqueued when a device is registered" do
    PushSubscription.subscribe(user: @user, endpoint: "https://push.example/1",
                               p256dh_key: "key", auth_key: "auth")

    assert_enqueued_jobs 1, only: DeliverPushNotificationJob do
      deliver
    end
  end

  test "severity defaults from the alert catalogue" do
    deliver

    assert_equal "critical", @user.notifications.sole.severity
  end
end
