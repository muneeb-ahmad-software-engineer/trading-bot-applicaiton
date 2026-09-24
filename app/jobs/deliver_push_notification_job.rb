# Sends one notification to every push subscription a user has.
#
# Runs in the background because a push service is a third party: it can be
# slow or down, and neither should delay the request that triggered the alert.
class DeliverPushNotificationJob < ApplicationJob
  queue_as :default

  # Endpoints that are permanently gone should not be retried.
  discard_on ActiveRecord::RecordNotFound

  def perform(notification_id)
    notification = Notification.find(notification_id)
    delivered = Notifications::PushSender.call(notification:).payload.to_i

    notification.update_column(:pushed_at, Time.current) if delivered.positive?
  end
end
