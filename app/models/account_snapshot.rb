# A point-in-time record of the broker account, kept for history.
#
# Written at most once per SAMPLE_INTERVAL rather than on every terminal report:
# a report every ten seconds would be 8,640 rows per user per day, to support
# charts and a drawdown figure that do not need that resolution. Current state
# lives in AccountState.
class AccountSnapshot < ApplicationRecord
  # How much detail history keeps.
  SAMPLE_INTERVAL = 1.minute

  # How long it is kept for. Drawdown looks back 30 days, so this leaves ample
  # margin while bounding the table.
  RETENTION = 90.days

  belongs_to :user
  belongs_to :strategy, optional: true

  validates :balance, :equity, presence: true, numericality: true
  validates :recorded_at, presence: true

  scope :latest_first, -> { order(recorded_at: :desc) }
  scope :older_than, ->(cutoff) { where(recorded_at: ...cutoff) }

  # True when enough time has passed since this user's last sample.
  def self.due_for?(user, now: Time.current)
    last = where(user:).maximum(:recorded_at)

    last.nil? || last <= now - SAMPLE_INTERVAL
  end
end
