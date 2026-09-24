module Notifications
  # Creates a notification and fans it out to the channels the user allows.
  #
  # The important behaviour here is what it *does not* do: it does not send the
  # same alert twice for a situation that is still ongoing. The stale-terminal
  # monitor runs every minute, and a terminal that has stopped reporting stays
  # stopped. Without suppression the user would be alerted every minute until
  # they muted everything — which is how alerting systems become useless.
  class Deliver < ApplicationService
    def initialize(user:, alert_type:, title: nil, body:, dedup_key:, subject: nil,
                   url: nil, metadata: {}, severity: nil)
      @user = user
      @alert_type = alert_type.to_s
      @title = title || AlertType.title(@alert_type)
      @body = body
      @dedup_key = dedup_key
      @subject = subject
      @url = url
      @metadata = metadata
      @severity = severity || AlertType.severity(@alert_type)
    end

    def call
      return failure("unknown_alert_type", "Unknown alert type #{alert_type}") unless AlertType.exists?(alert_type)

      existing = Notification.open_for(user, dedup_key)
      return success(existing) if existing   # situation already reported

      notification = Notification.create!(
        user:, alert_type:, title:, body:, dedup_key:, subject:, url:,
        severity:, metadata:
      )

      deliver_email(notification)
      deliver_push(notification)

      success(notification)
    rescue ActiveRecord::RecordInvalid => e
      failure("invalid_notification", e.record.errors.full_messages.to_sentence)
    end

    private

    attr_reader :user, :alert_type, :title, :body, :dedup_key, :subject, :url, :metadata, :severity

    def preferences = @preferences ||= NotificationPreferences.new(user)

    def deliver_email(notification)
      return unless preferences.enabled?(alert_type, "email")

      AlertMailer.alert(notification).deliver_later
      notification.update_column(:emailed_at, Time.current)
    end

    def deliver_push(notification)
      return unless preferences.enabled?(alert_type, "push")
      return if user.push_subscriptions.active.none?

      DeliverPushNotificationJob.perform_later(notification.id)
    end
  end
end
