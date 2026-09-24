require "test_helper"

class NotificationSettingsTest < ActionDispatch::IntegrationTest
  PASSWORD = "a-long-test-password".freeze

  setup do
    @user = users(:verified)
    post login_path, params: { email_address: @user.email_address, password: PASSWORD }
  end

  test "preferences page lists every alert type and channel" do
    get notification_settings_path

    assert_response :success
    AlertType::ALL.each_value { |config| assert_match config[:title], response.body }
  end

  test "preferences can be turned off and are persisted" do
    patch notification_settings_path, params: {
      preferences: { "basket_closed" => { "email" => "0", "push" => "1" } }
    }

    preferences = @user.reload.notification_preferences_object
    assert_not preferences.enabled?("basket_closed", "email")
    assert preferences.enabled?("basket_closed", "push")
  end

  test "a mandatory alert stays on however the form is submitted" do
    patch notification_settings_path, params: {
      preferences: { "terminal_stale" => { "email" => "0", "push" => "0" } }
    }

    preferences = @user.reload.notification_preferences_object
    assert preferences.enabled?("terminal_stale", "email"), "a critical alert must not be silenceable"
    assert preferences.enabled?("terminal_stale", "push")
  end

  test "the mandatory alert is rendered disabled, not merely ignored" do
    get notification_settings_path

    # The interface must not offer a control that silently does nothing.
    assert_select "input[type=checkbox][disabled][checked]"
    assert_match(/Always on/i, response.body)
  end

  test "a device can be registered and removed" do
    assert_difference "PushSubscription.count", 1 do
      post push_subscriptions_path, params: {
        endpoint: "https://push.example/device-1", p256dh_key: "k", auth_key: "a"
      }, as: :json
    end
    assert_response :created

    device = PushSubscription.last
    assert_difference "PushSubscription.count", -1 do
      delete push_subscription_path(device)
    end
  end

  test "a user cannot remove another account's device" do
    theirs = PushSubscription.subscribe(user: users(:unverified),
                                        endpoint: "https://push.example/theirs",
                                        p256dh_key: "k", auth_key: "a")

    delete push_subscription_path(theirs)

    assert_response :not_found
    assert PushSubscription.exists?(theirs.id)
  end

  test "alerts page shows the user's notifications only" do
    Notification.create!(user: @user, alert_type: "terminal_stale", title: "Mine",
                         body: "my alert", dedup_key: "a", severity: "critical")
    Notification.create!(user: users(:unverified), alert_type: "terminal_stale", title: "Theirs",
                         body: "their alert", dedup_key: "b", severity: "critical")

    get notifications_path

    assert_match "my alert", response.body
    assert_no_match(/their alert/, response.body)
  end

  test "opening the alerts page marks them read" do
    Notification.create!(user: @user, alert_type: "terminal_stale", title: "t",
                         body: "b", dedup_key: "a", severity: "critical")

    get notifications_path

    assert_equal 0, @user.notifications.unread.count
  end

  test "notification pages require authentication" do
    delete logout_path

    [ notification_settings_path, notifications_path ].each do |path|
      get path
      assert_redirected_to login_path
    end
  end
end
