require "test_helper"

# Push delivery.
#
# A push service is a third party that fails in ordinary ways, and this class is
# almost entirely a set of decisions about those failures. None of them can be
# provoked by talking to the real service, so every test here stands in for it
# and asserts what the application did in response.
#
# The rule underneath all of it: an alert exists to tell someone their trading
# bot stopped reporting. Losing that message because one device of theirs was
# uninstalled last month is not an acceptable outcome.
class PushSenderTest < ActiveSupport::TestCase
  setup do
    @user = users(:verified)
    PushSubscription.delete_all
  end

  # ------------------------------------------------------------------ Helpers

  # The push protocol answers with an HTTP status; the gem turns the ones that
  # mean "this endpoint is finished" into these two exceptions.
  def response(code, message) = Struct.new(:code, :message, :body).new(code, message, message)
  def endpoint_gone = WebPush::ExpiredSubscription.new(response("410", "Gone"), "push.example")
  def endpoint_unknown = WebPush::InvalidSubscription.new(response("404", "Not Found"), "push.example")

  def notification(severity: "critical", url: "/dashboard", user: @user)
    Notification.create!(user:, alert_type: "terminal_stale", title: "Terminal stopped reporting",
                         body: "Your MT5 terminal stopped sending updates.",
                         dedup_key: "terminal_stale:#{SecureRandom.hex(4)}", severity:, url:)
  end

  def device(name, user: @user)
    PushSubscription.subscribe(user:, endpoint: "https://push.example/#{name}",
                               p256dh_key: "key-#{name}", auth_key: "auth-#{name}")
  end

  # Stands in for the push service. The replacement receives the keyword
  # arguments the application passed, so a test can both assert on them and
  # choose an outcome.
  def sending(implementation, &block) = stubbing(WebPush, :payload_send, implementation, &block)
  def accepting(&block) = sending(->(**) { true }, &block)
  def refusing(error, &block) = sending(->(**) { raise error }, &block)
  def without_vapid_keys(&block) = stubbing(Rails.application.credentials, :web_push, -> { nil }, &block)

  def send_now(note = notification) = Notifications::PushSender.call(notification: note)

  # ------------------------------------------------------------ Preconditions

  test "delivery is refused, not attempted, when no VAPID keys are configured" do
    device("a")
    contacted = false

    result = without_vapid_keys do
      sending(->(**) { contacted = true; true }) { send_now }
    end

    assert_predicate result, :failure?
    assert_equal "push_not_configured", result.error_code
    assert_not contacted, "the push service must not be called without signing keys"
  end

  test "a user with no devices is a success that delivered nothing" do
    result = sending(->(**) { flunk "the push service must not be contacted" }) { send_now }

    assert_predicate result, :success?
    assert_equal 0, result.payload
  end

  # ---------------------------------------------------------------- Delivery

  test "every active device is contacted and counted" do
    3.times { |i| device(i) }
    contacted = []

    result = sending(->(**kwargs) { contacted << kwargs[:endpoint]; true }) { send_now }

    assert_equal 3, contacted.size
    assert_equal 3, result.payload
  end

  test "a delivery records that the device was reached" do
    subscription = device("a")

    accepting { send_now }

    subscription.reload
    assert_not_nil subscription.last_used_at
    assert_equal 0, subscription.failure_count
    assert_nil subscription.failed_at
  end

  test "the payload carries what the service worker needs to render the alert" do
    device("a")
    note = notification
    captured = nil

    sending(->(**kwargs) { captured = kwargs; true }) { send_now(note) }
    payload = JSON.parse(captured[:message])

    assert_equal note.title, payload["title"]
    assert_equal note.body, payload["body"]
    assert_equal note.severity, payload["severity"]
    assert_equal note.url, payload["url"]
    assert_equal note.id, payload["notification_id"]
  end

  test "the payload is tagged by situation so a repeat replaces the banner rather than stacking" do
    # Two alerts about the same ongoing situation must not leave two banners on
    # the lock screen. The tag is what lets the browser collapse them.
    device("a")
    note = notification
    captured = nil

    sending(->(**kwargs) { captured = kwargs; true }) { send_now(note) }

    assert_equal note.dedup_key, JSON.parse(captured[:message])["tag"]
  end

  test "an alert with no destination falls back to the dashboard" do
    device("a")
    captured = nil

    sending(->(**kwargs) { captured = kwargs; true }) { send_now(notification(url: nil)) }

    assert_equal "/dashboard", JSON.parse(captured[:message])["url"]
  end

  test "the device's own keys and endpoint are used" do
    device("a")
    captured = nil

    sending(->(**kwargs) { captured = kwargs; true }) { send_now }

    assert_equal "https://push.example/a", captured[:endpoint]
    assert_equal "key-a", captured[:p256dh]
    assert_equal "auth-a", captured[:auth]
  end

  test "requests are signed with the configured VAPID keys and a contact address" do
    device("a")
    captured = nil

    sending(->(**kwargs) { captured = kwargs; true }) { send_now }

    assert_equal Rails.application.credentials.web_push[:public_key], captured[:vapid][:public_key]
    assert_equal Rails.application.credentials.web_push[:private_key], captured[:vapid][:private_key]
    assert_match(/\Amailto:/, captured[:vapid][:subject])
  end

  test "a critical alert is sent with high urgency and anything else is not" do
    # Urgency decides whether a dozing phone is woken. "Your terminal stopped
    # reporting and you have open positions" is worth waking someone for;
    # "your terminal is back" is not.
    device("a")
    captured = nil

    sending(->(**kwargs) { captured = kwargs; true }) { send_now(notification(severity: "critical")) }
    assert_equal "high", captured[:urgency]

    sending(->(**kwargs) { captured = kwargs; true }) { send_now(notification(severity: "info")) }
    assert_equal "normal", captured[:urgency]

    sending(->(**kwargs) { captured = kwargs; true }) { send_now(notification(severity: "warning")) }
    assert_equal "normal", captured[:urgency]
  end

  # ------------------------------------------------- Permanently gone devices

  test "an endpoint the service reports as gone is removed at once" do
    device("a")

    assert_difference "PushSubscription.count", -1 do
      refusing(endpoint_gone) { send_now }
    end
  end

  test "an endpoint the service does not recognise is removed at once" do
    device("a")

    assert_difference "PushSubscription.count", -1 do
      refusing(endpoint_unknown) { send_now }
    end
  end

  test "a removed endpoint does not count as a delivery" do
    device("a")

    result = refusing(endpoint_gone) { send_now }

    assert_predicate result, :success?
    assert_equal 0, result.payload
  end

  # ----------------------------------------------------- Transient failures

  test "a single failure is counted, not punished" do
    subscription = device("a")

    assert_no_difference "PushSubscription.count" do
      refusing(RuntimeError.new("connection reset")) { send_now }
    end

    subscription.reload
    assert_equal 1, subscription.failure_count
    assert_not_nil subscription.failed_at
    assert_not subscription.expired?
  end

  test "a device is retired only once failures reach the limit" do
    subscription = device("a")

    (PushSubscription::MAX_FAILURES - 1).times do
      refusing(RuntimeError.new("timeout")) { send_now }
    end

    assert PushSubscription.exists?(subscription.id),
           "a device must survive every failure short of the limit"

    refusing(RuntimeError.new("timeout")) { send_now }

    assert_not PushSubscription.exists?(subscription.id)
  end

  test "a device already past the limit is never contacted again" do
    subscription = device("a")
    subscription.update_columns(failure_count: PushSubscription::MAX_FAILURES, failed_at: Time.current)

    result = sending(->(**) { flunk "a retired device must not be contacted" }) { send_now }

    assert_equal 0, result.payload
  end

  test "a device that recovers before the limit keeps its place" do
    subscription = device("a")
    (PushSubscription::MAX_FAILURES - 1).times { refusing(RuntimeError.new("timeout")) { send_now } }

    accepting { send_now }

    assert_equal 0, subscription.reload.failure_count
    assert PushSubscription.exists?(subscription.id)
  end

  test "a transient failure does not count as a delivery" do
    device("a")

    result = refusing(RuntimeError.new("timeout")) { send_now }

    assert_predicate result, :success?
    assert_equal 0, result.payload
  end

  # --------------------------------------------------- Isolation of failures

  test "one failing device does not stop the others being told" do
    # The whole point of the class. A user with a dead tablet and a working
    # phone must still be woken on the phone.
    first = device("a")
    device("b")
    device("c")
    contacted = []

    result = sending(lambda { |**kwargs|
      contacted << kwargs[:endpoint]
      raise "connection reset" if kwargs[:endpoint] == first.endpoint

      true
    }) { send_now }

    assert_equal 3, contacted.size, "every device must be attempted"
    assert_equal 2, result.payload
  end

  test "a device removed mid-run does not stop the others being told" do
    first = device("a")
    device("b")
    contacted = []

    result = sending(lambda { |**kwargs|
      contacted << kwargs[:endpoint]
      raise endpoint_gone if kwargs[:endpoint] == first.endpoint

      true
    }) { send_now }

    assert_equal 2, contacted.size
    assert_equal 1, result.payload
    assert_equal 1, PushSubscription.count
  end

  test "every device can fail without the run itself failing" do
    2.times { |i| device(i) }

    result = refusing(RuntimeError.new("everything is down")) { send_now }

    # A failed send is a reported outcome, not an exception: the caller is a
    # background job whose retry would only re-send to the same dead endpoints.
    assert_predicate result, :success?
    assert_equal 0, result.payload
  end

  # ------------------------------------------------------------- Scoping

  test "only the alerted user's devices are contacted" do
    device("mine")
    device("theirs", user: users(:unverified))
    contacted = []

    result = sending(->(**kwargs) { contacted << kwargs[:endpoint]; true }) { send_now }

    assert_equal [ "https://push.example/mine" ], contacted
    assert_equal 1, result.payload
  end

  test "another account's device is untouched by a failure on this one" do
    device("mine")
    theirs = device("theirs", user: users(:unverified))

    refusing(endpoint_gone) { send_now }

    assert PushSubscription.exists?(theirs.id)
  end
end
