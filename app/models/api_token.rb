# A bearer token issued to a non-browser client: the MT5 Expert Advisor, or a
# native mobile application.
#
# Security properties:
#   * The plaintext token is generated once, shown once, and never stored. Only
#     its SHA-256 digest is persisted, so a database disclosure does not yield
#     usable credentials.
#   * Lookup is by digest, so it is a single indexed query rather than a scan
#     with per-row comparison.
#   * Tokens are revocable immediately, which is the main reason this project
#     uses opaque tokens rather than self-contained JWTs.
class ApiToken < ApplicationRecord
  BYTE_LENGTH = 32
  PREFIX = "ggk_".freeze

  belongs_to :user
  # Nullified, not destroyed: losing a token must not delete the record of the
  # terminal that was using it, or the execution manager would forget a live
  # process exists.
  has_one :mt5_instance, dependent: :nullify

  # A terminal connection is identified by the token it authenticates with, so
  # it cannot outlive the token. Declared here rather than relying on the order
  # associations happen to be listed in on User: destroying a user destroys
  # api_tokens first, and without this the foreign key from terminal_connections
  # blocks the whole deletion.
  has_one :terminal_connection, dependent: :destroy

  validates :name, presence: true, length: { maximum: 60 }
  validates :token_digest, presence: true, uniqueness: true

  scope :active, -> { where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  # Set only on the instance returned by .issue, so a controller can display it
  # once. It is never reloaded from the database because it is not stored there.
  attr_reader :plaintext_token

  class << self
    def issue(user:, name:, expires_at: nil)
      token = "#{PREFIX}#{SecureRandom.urlsafe_base64(BYTE_LENGTH)}"

      record = create!(user:, name:, expires_at:, token_digest: digest(token))
      record.instance_variable_set(:@plaintext_token, token)
      record
    end

    # Returns the active token matching the presented string, or nil.
    def authenticate(presented)
      return nil if presented.blank?

      active.find_by(token_digest: digest(presented))
    end

    def digest(token)
      OpenSSL::Digest::SHA256.hexdigest(token)
    end
  end

  def revoke! = update!(revoked_at: Time.current)

  def active? = revoked_at.nil? && (expires_at.nil? || expires_at.future?)

  # Recorded so a user can see when a terminal last called in. Throttled to one
  # write per hour so a polling EA does not generate a write on every request.
  def touch_last_used!
    return if last_used_at.present? && last_used_at > 1.hour.ago

    update_column(:last_used_at, Time.current)
  end

  # Safe to display: identifies the token without revealing it.
  def display_hint = "#{PREFIX}…#{token_digest.last(6)}"
end
