# The broker account a user's MT5 terminal signs in to.
#
# Kept in its own table rather than on the instance: instances are disposable
# and get recreated freely, credentials are entered once and must survive that.
class BrokerCredential < ApplicationRecord
  belongs_to :user

  # A broker password can place trades and, at some brokers, request a
  # withdrawal. Encrypted at rest, like every other credential in this
  # application, so a database dump does not hand over a trading account.
  encrypts :password

  validates :server, presence: true, length: { maximum: 120 }
  # MetaTrader account numbers are integers. Catching a pasted email address or
  # a portal username here turns a three-minute wait for a terminal that never
  # connects into an error next to the field that is wrong.
  validates :login, presence: true, length: { maximum: 60 },
                    format: { with: /\A\d+\z/, message: "must be the numeric MT5 account number" }
  validates :password, presence: true

  # Verification state is reset whenever the details change, because a
  # credential that was verified is only evidence about the values that were
  # verified. Carrying the tick over to an edited password would show a green
  # check beside something nothing has ever signed in with.
  before_save :reset_verification, if: -> { server_changed? || login_changed? || password_changed? }

  def live? = !demo?

  def verified? = last_verified_at.present?

  # Verified means a terminal signed in to this broker account with these
  # details and reported back. It is deliberately not something the user can
  # assert and not something this application can check on its own: nothing here
  # ever talks to a broker, so the only evidence that a login works is a
  # terminal that used it.
  def record_verification!
    return if last_verified_at.present? && last_verified_at > 1.hour.ago

    update_columns(last_verified_at: Time.current, last_verification_error: nil, updated_at: Time.current)
  end

  # Why the last attempt to use these details did not work, in the user's words
  # rather than the execution layer's. Truncated because it is rendered beside
  # the form and a page of MetaTrader diagnostics helps nobody.
  def record_verification_failure!(message)
    update_columns(last_verification_error: message.to_s.truncate(200), updated_at: Time.current)
  end

  # What may safely appear in a log line, a support conversation or an error
  # report. The password has no representation here at all — not masked, absent.
  def to_log = { server:, login: masked_login, demo: }

  # Never rendered anywhere. Defined so that an accidental interpolation of the
  # record into a log line cannot leak the password.
  def inspect = "#<BrokerCredential id=#{id} #{to_log.to_json}>"

  private

  def reset_verification
    self.last_verified_at = nil
    self.last_verification_error = nil
  end

  def masked_login
    text = login.to_s
    return "•" * text.length if text.length <= 4

    "#{'•' * (text.length - 4)}#{text.last(4)}"
  end
end
