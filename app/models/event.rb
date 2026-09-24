# An append-only audit record.
#
# Events are facts about things that already happened, so they are never updated
# or deleted. Recording one must never break the action it describes: a failure
# to write an audit row should not roll back a user's strategy stopping.
class Event < ApplicationRecord
  belongs_to :user
  belongs_to :subject, polymorphic: true, optional: true

  SOURCES = %w[web api system].freeze

  # Long enough to investigate an incident well after the fact, bounded so the
  # table does not grow forever.
  RETENTION = 1.year

  validates :action, presence: true
  validates :occurred_at, presence: true
  validates :source, inclusion: { in: SOURCES }

  scope :recent_first, -> { order(occurred_at: :desc) }
  scope :for_action, ->(prefix) { where("action LIKE ?", "#{sanitize_sql_like(prefix)}%") }

  # Read-only by construction. Anything that can be edited after the fact is not
  # an audit trail.
  #
  # Note this also blocks #destroy, so associations that clean events up must
  # use delete_all rather than destroy (see User).
  def readonly? = persisted?

  class << self
    def record(action, user:, subject: nil, metadata: {}, source: "web", ip_address: nil)
      create!(
        action:, user:, subject:, source:, ip_address:,
        metadata: metadata.compact,
        occurred_at: Time.current
      )
    rescue StandardError => e
      # Auditing is important but must not take the application down with it.
      # The failure is reported loudly rather than swallowed silently.
      Rails.logger.error("Event.record failed for #{action}: #{e.class} #{e.message}")
      Rails.error.report(e, handled: true, context: { action:, user_id: user&.id }) if Rails.respond_to?(:error)
      nil
    end
  end

  # Human-readable summary, used by the activity list.
  def description
    case action
    when "strategy.created"     then "Created strategy #{subject_name}"
    when "strategy.updated"     then "Updated strategy #{subject_name}"
    when "strategy.started"     then "Started strategy #{subject_name}"
    when "strategy.stopped"     then "Stopped strategy #{subject_name}"
    when "strategy.deleted"     then "Deleted strategy #{metadata['name']}"
    when "broker_credential.saved"   then "Saved broker account details"
    when "broker_credential.removed" then "Removed broker account details"
    when "api_token.issued"     then "Issued API token #{metadata['name']}"
    when "api_token.revoked"    then "Revoked API token #{metadata['name']}"
    when "api_token.regenerated" then "Regenerated API token #{metadata['name']}"
    when "api_token.deleted"    then "Deleted API token #{metadata['name']}"
    when "two_factor.enabled"   then "Turned on two-factor authentication"
    when "two_factor.disabled"  then "Turned off two-factor authentication"
    when "recovery_codes.regenerated" then "Regenerated recovery codes"
    when "session.started"      then "Signed in"
    when "password.changed"     then "Changed password"
    when "email.verified"       then "Verified email address"
    when "terminal.connected"   then "MT5 terminal connected"
    else action.humanize
    end
  end

  private

  def subject_name
    return metadata["name"] if metadata["name"].present?
    subject.respond_to?(:name) ? subject.name : "##{subject_id}"
  end
end
