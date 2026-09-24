# An append-only record of something the execution layer did.
#
# Separate from Event, which audits what a *user* did. Most of what happens to
# an instance happens with nobody in the room: a process dies at 03:00 and the
# reconciler restarts it. That is exactly the history worth keeping.
class Mt5InstanceEvent < ApplicationRecord
  belongs_to :mt5_instance
  belongs_to :user, optional: true

  SOURCES = %w[web api system].freeze

  validates :action, presence: true
  validates :occurred_at, presence: true
  validates :source, inclusion: { in: SOURCES }

  scope :recent_first, -> { order(occurred_at: :desc) }

  # Read-only by construction, like Event. An audit trail that can be edited
  # after the fact is not an audit trail.
  def readonly? = persisted?

  def description
    return "#{action} (#{from_state} → #{to_state})" if from_state.present? && to_state.present?

    action
  end
end
