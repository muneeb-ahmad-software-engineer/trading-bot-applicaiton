# A browser or installed PWA that has granted permission to receive push.
class PushSubscription < ApplicationRecord
  # A push service returns 404 or 410 when an endpoint is permanently gone —
  # the browser was uninstalled, or permission revoked. Those are pruned
  # immediately. Transient failures are counted and pruned only once they
  # repeat, so one network blip does not unsubscribe a working device.
  MAX_FAILURES = 5

  belongs_to :user

  validates :endpoint, presence: true, uniqueness: true
  validates :p256dh_key, :auth_key, presence: true

  # The exact complement of #expired?. Written as one condition rather than
  # "never failed OR under the limit": failure_count and failed_at are set by
  # two separate writes, so a row can exist with a high count and no failed_at,
  # and the older form called such a row active while #expired? called it dead.
  # One predicate, one definition.
  scope :active, -> { where(arel_table[:failure_count].lt(MAX_FAILURES)) }

  def self.subscribe(user:, endpoint:, p256dh_key:, auth_key:, user_agent: nil)
    subscription = find_or_initialize_by(endpoint:)
    subscription.assign_attributes(
      user:, p256dh_key:, auth_key:, user_agent:,
      failed_at: nil, failure_count: 0
    )
    subscription.save!
    subscription
  end

  def record_success!
    update_columns(last_used_at: Time.current, failure_count: 0, failed_at: nil)
  end

  def record_failure!
    increment!(:failure_count)
    update_column(:failed_at, Time.current)
  end

  def expired? = failure_count >= MAX_FAILURES
end
