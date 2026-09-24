require "test_helper"

# The job exists so that a push service — a third party that can be slow or
# down — never delays or breaks the thing that raised the alert. What it records
# afterwards is the only evidence a user has that their device was told.
class DeliverPushNotificationJobTest < ActiveJob::TestCase
  setup do
    @user = users(:verified)
    PushSubscription.delete_all
  end

  def notification
    Notification.create!(user: @user, alert_type: "terminal_stale", title: "Terminal stopped reporting",
                         body: "Your MT5 terminal stopped sending updates.",
                         dedup_key: "terminal_stale:#{SecureRandom.hex(4)}",
                         severity: "critical", url: "/dashboard")
  end

  def device(name = "a")
    PushSubscription.subscribe(user: @user, endpoint: "https://push.example/#{name}",
                               p256dh_key: "k", auth_key: "a")
  end

  def sending(implementation, &block) = stubbing(WebPush, :payload_send, implementation, &block)
  def accepting(&block) = sending(->(**) { true }, &block)
  def without_vapid_keys(&block) = stubbing(Rails.application.credentials, :web_push, -> { nil }, &block)

  test "a delivered alert is stamped as pushed" do
    device
    note = notification

    accepting { DeliverPushNotificationJob.perform_now(note.id) }

    assert_not_nil note.reload.pushed_at
  end

  test "an alert nothing accepted is not stamped as pushed" do
    # pushed_at is what the interface reads to say a device was told. Stamping
    # it after a failed send would be a claim the application cannot support.
    device
    note = notification

    sending(->(**) { raise "connection reset" }) { DeliverPushNotificationJob.perform_now(note.id) }

    assert_nil note.reload.pushed_at
  end

  test "an alert with nowhere to send is not stamped as pushed" do
    note = notification

    accepting { DeliverPushNotificationJob.perform_now(note.id) }

    assert_nil note.reload.pushed_at
  end

  test "a partial delivery still counts as pushed" do
    # One device of several failing does not mean the user was not reached.
    failing = device("a")
    device("b")
    note = notification

    sending(lambda { |**kwargs|
      raise "connection reset" if kwargs[:endpoint] == failing.endpoint

      true
    }) { DeliverPushNotificationJob.perform_now(note.id) }

    assert_not_nil note.reload.pushed_at
  end

  test "an unconfigured push setup fails quietly rather than raising" do
    # The failure Result carries a nil payload. Reaching for a delivery count on
    # it must not blow up the job and put it into a retry loop it can never
    # escape — the keys will not appear on their own.
    device
    note = notification

    assert_nothing_raised do
      without_vapid_keys { DeliverPushNotificationJob.perform_now(note.id) }
    end

    assert_nil note.reload.pushed_at
  end

  test "an alert deleted before the job runs is discarded, not retried" do
    note = notification
    id = note.id
    note.destroy

    assert_nothing_raised { DeliverPushNotificationJob.perform_now(id) }
  end

  test "the job is enqueued rather than run inline when an alert is delivered" do
    # A push to a third party must not sit inside the request that raised the
    # alert — on this platform that request is a terminal reporting its state.
    device

    assert_enqueued_with job: DeliverPushNotificationJob, queue: "default" do
      Notifications::Deliver.call(
        user: @user, alert_type: "terminal_stale", body: "Terminal stopped reporting.",
        dedup_key: "terminal_stale:#{SecureRandom.hex(4)}"
      )
    end
  end

  test "the whole path from alert to device works end to end" do
    device
    contacted = []

    perform_enqueued_jobs do
      sending(->(**kwargs) { contacted << kwargs[:endpoint]; true }) do
        Notifications::Deliver.call(
          user: @user, alert_type: "terminal_stale", body: "Terminal stopped reporting.",
          dedup_key: "terminal_stale:#{SecureRandom.hex(4)}"
        )
      end
    end

    assert_equal [ "https://push.example/a" ], contacted
    assert_not_nil @user.notifications.sole.pushed_at
  end
end
