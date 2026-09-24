# A delivered alert.
class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :subject, polymorphic: true, optional: true

  SEVERITIES = %w[info warning critical].freeze

  # Only resolved notifications are pruned; an unresolved one describes a
  # situation that is still happening, however old it is.
  RETENTION = 90.days

  validates :alert_type, presence: true, inclusion: { in: ->(_) { AlertType.keys } }
  validates :title, :body, :dedup_key, presence: true
  validates :severity, inclusion: { in: SEVERITIES }

  scope :recent_first, -> { order(created_at: :desc) }
  scope :unread, -> { where(read_at: nil) }
  scope :unresolved, -> { where(resolved_at: nil) }

  def read? = read_at.present?

  # Written as regular methods, not endless ones: `def x = y unless z` binds the
  # modifier to the *definition* rather than the body, so the guard runs once at
  # class-load time instead of on each call.
  def mark_read!
    update!(read_at: Time.current) unless read?
  end

  def resolve!
    update!(resolved_at: Time.current) if resolved_at.nil?
  end

  # An alert about an ongoing situation that is still open. Used to suppress
  # repeats and to find what to resolve when the situation ends.
  def self.open_for(user, dedup_key)
    unresolved.find_by(user:, dedup_key:)
  end
end
