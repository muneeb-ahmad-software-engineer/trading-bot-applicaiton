# One connected MT5 terminal, identified by the API token it authenticates with.
#
# Liveness is derived from last_report_at rather than stored as a boolean: a
# terminal that crashes or loses connectivity stops reporting, and must then
# read as stale rather than staying "connected" indefinitely. On a trading
# dashboard, "not reporting" and "flat" are very different states and must never
# be conflated.
class TerminalConnection < ApplicationRecord
  STALE_AFTER = 90.seconds

  belongs_to :user
  belongs_to :api_token
  belongs_to :strategy, optional: true

  validates :symbol, presence: true

  def live? = last_report_at.present? && last_report_at > STALE_AFTER.ago

  def status
    return :never_connected if last_report_at.blank?

    live? ? :live : :stale
  end

  def spread_points_or_derived
    return spread_points if spread_points.present?
    return nil if bid.blank? || ask.blank?

    ((ask - bid) * 100).round
  end
end
