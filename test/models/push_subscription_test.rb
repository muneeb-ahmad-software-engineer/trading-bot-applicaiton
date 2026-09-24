require "test_helper"

# A push subscription is a claim that some browser, somewhere, is still willing
# to receive alerts. The claim goes stale silently — a device is wiped, an
# application uninstalled, permission revoked — so most of what matters here is
# how a subscription is retired, and how carefully.
#
# The balance being struck: retire too eagerly and a user stops being told their
# bot died because their train went through a tunnel; retire too reluctantly and
# the sender spends every alert talking to endpoints that will never answer.
class PushSubscriptionTest < ActiveSupport::TestCase
  setup { @user = users(:verified) }

  def subscribe(endpoint: "https://push.example/abc", user: @user, **overrides)
    PushSubscription.subscribe(user:, endpoint:, p256dh_key: "k", auth_key: "a", **overrides)
  end

  # --------------------------------------------------------------- Subscribing

  test "re-subscribing the same browser updates rather than duplicates" do
    2.times do
      PushSubscription.subscribe(user: @user, endpoint: "https://push.example/abc",
                                 p256dh_key: "k", auth_key: "a")
    end

    # Duplicates would deliver the same alert several times to one device.
    assert_equal 1, PushSubscription.count
  end

  test "re-subscribing refreshes the keys the push service will be given" do
    # A browser may rotate its keys for the same endpoint. Keeping the old ones
    # would encrypt every future payload so that device cannot read it.
    subscribe
    PushSubscription.subscribe(user: @user, endpoint: "https://push.example/abc",
                               p256dh_key: "new-key", auth_key: "new-auth")

    subscription = PushSubscription.sole
    assert_equal "new-key", subscription.p256dh_key
    assert_equal "new-auth", subscription.auth_key
  end

  test "re-subscribing revives a device that had been failing" do
    subscription = subscribe
    3.times { subscription.record_failure! }

    subscribe

    subscription.reload
    assert_equal 0, subscription.failure_count
    assert_nil subscription.failed_at
  end

  test "an endpoint moves with the browser when a different account signs in" do
    # Endpoint is unique across the table, so the same browser subscribing under
    # a second account must re-point the row rather than collide. Leaving it on
    # the first account would send one user's alerts to another's device.
    subscribe
    subscribe(user: users(:unverified))

    assert_equal 1, PushSubscription.count
    assert_equal users(:unverified), PushSubscription.sole.user
  end

  test "the user agent is recorded so a device is recognisable in settings" do
    subscribe(user_agent: "Firefox on Android")

    assert_equal "Firefox on Android", PushSubscription.sole.user_agent
  end

  test "an endpoint and its keys are all required" do
    assert_not PushSubscription.new(user: @user, p256dh_key: "k", auth_key: "a").valid?
    assert_not PushSubscription.new(user: @user, endpoint: "e", auth_key: "a").valid?
    assert_not PushSubscription.new(user: @user, endpoint: "e", p256dh_key: "k").valid?
  end

  test "the same endpoint cannot be registered twice" do
    subscribe

    duplicate = PushSubscription.new(user: @user, endpoint: "https://push.example/abc",
                                     p256dh_key: "k", auth_key: "a")

    assert_not duplicate.valid?
    assert_predicate duplicate.errors[:endpoint], :any?
  end

  # ------------------------------------------------------------ Retiring

  test "repeated failures retire a device but one does not" do
    subscription = PushSubscription.subscribe(user: @user, endpoint: "https://push.example/x",
                                              p256dh_key: "k", auth_key: "a")

    subscription.record_failure!
    assert_not subscription.expired?, "a single network blip must not unsubscribe a working device"

    (PushSubscription::MAX_FAILURES - 1).times { subscription.record_failure! }
    assert_predicate subscription, :expired?
  end

  test "expiry is reached exactly at the failure limit, not before it" do
    subscription = subscribe

    (PushSubscription::MAX_FAILURES - 1).times { subscription.record_failure! }
    assert_not subscription.expired?, "one failure short of the limit is still a live device"

    subscription.record_failure!
    assert_predicate subscription, :expired?
  end

  test "success clears an earlier failure" do
    subscription = PushSubscription.subscribe(user: @user, endpoint: "https://push.example/y",
                                              p256dh_key: "k", auth_key: "a")
    subscription.record_failure!
    subscription.record_success!

    assert_equal 0, subscription.reload.failure_count
    assert_nil subscription.failed_at
  end

  test "a success records when the device was last reached" do
    subscription = subscribe

    subscription.record_success!

    assert_not_nil subscription.reload.last_used_at
  end

  test "a run of failures short of the limit is wiped out by a single success" do
    # Alerts matter most after an outage. A device that comes back must start
    # from a clean slate rather than being retired by failures already over.
    subscription = subscribe
    (PushSubscription::MAX_FAILURES - 1).times { subscription.record_failure! }

    subscription.record_success!

    assert_not subscription.expired?
    assert_equal 0, subscription.reload.failure_count
  end

  # ------------------------------------------------------- The active scope

  test "the active scope and expiry are the same question asked two ways" do
    # They are used interchangeably — the scope decides who gets contacted,
    # expired? decides who gets deleted — so any disagreement between them
    # leaves rows that are contacted forever or deleted while still working.
    subscription = subscribe

    (0..PushSubscription::MAX_FAILURES + 1).each do |count|
      subscription.update_columns(failure_count: count, failed_at: count.zero? ? nil : Time.current)

      assert_equal PushSubscription.active.exists?(id: subscription.id),
                   !subscription.reload.expired?,
                   "active and expired? disagree at failure_count #{count}"
    end
  end

  test "a high failure count retires a device even if the failure timestamp is missing" do
    # failure_count and failed_at are written separately, so a process dying
    # between the two leaves a row with a count and no timestamp. That row must
    # still be treated as dead.
    subscription = subscribe
    subscription.update_columns(failure_count: PushSubscription::MAX_FAILURES, failed_at: nil)

    assert_not PushSubscription.active.exists?(id: subscription.id)
    assert_predicate subscription.reload, :expired?
  end

  test "a device that has never failed is active" do
    subscription = subscribe

    assert PushSubscription.active.exists?(id: subscription.id)
  end

  test "deleting a user removes their devices" do
    subscribe

    assert_difference "PushSubscription.count", -1 do
      @user.destroy
    end
  end
end
