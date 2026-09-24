module Notifications
  # Delivers one notification to every active push subscription a user has.
  #
  # A push service is a third party that fails in ordinary ways. The rules here:
  #
  #   * 404/410 means the endpoint is permanently gone (browser uninstalled,
  #     permission revoked) — delete it immediately rather than retrying forever.
  #   * Any other failure is counted. A device is only unsubscribed once
  #     failures repeat, so a single network blip does not silently stop a
  #     user's alerts.
  #   * One device failing must never prevent the others from being told.
  class PushSender < ApplicationService
    def initialize(notification:)
      @notification = notification
    end

    def call
      return failure("push_not_configured", "VAPID keys are not configured.") if vapid.blank?

      delivered = 0

      @notification.user.push_subscriptions.active.find_each do |subscription|
        delivered += 1 if send_to(subscription)
      end

      success(delivered)
    end

    private

    def vapid = @vapid ||= Rails.application.credentials.web_push

    def payload
      {
        title: @notification.title,
        body: @notification.body,
        severity: @notification.severity,
        url: @notification.url || "/dashboard",
        tag: @notification.dedup_key,   # replaces an existing banner for the same situation
        notification_id: @notification.id
      }.to_json
    end

    def send_to(subscription)
      WebPush.payload_send(
        message: payload,
        endpoint: subscription.endpoint,
        p256dh: subscription.p256dh_key,
        auth: subscription.auth_key,
        vapid: {
          subject: "mailto:#{ENV.fetch('MAILER_FROM', 'no-reply@example.com')}",
          public_key: vapid[:public_key],
          private_key: vapid[:private_key]
        },
        urgency: @notification.severity == "critical" ? "high" : "normal"
      )

      subscription.record_success!
      true
    rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription
      # Permanently gone. Removing it keeps the list honest.
      subscription.destroy
      false
    rescue StandardError => e
      Rails.logger.warn("Push delivery failed for subscription #{subscription.id}: #{e.class} #{e.message}")
      subscription.record_failure!
      subscription.destroy if subscription.expired?
      false
    end
  end
end
