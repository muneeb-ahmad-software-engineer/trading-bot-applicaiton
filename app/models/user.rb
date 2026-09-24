class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :api_tokens, dependent: :destroy
  has_many :strategies, dependent: :destroy
  has_many :terminal_connections, dependent: :destroy
  has_many :account_snapshots, dependent: :delete_all
  has_one :account_state, dependent: :destroy
  has_many :recovery_codes, dependent: :destroy
  # Terminals are destroyed with the account, but only after #deprovision_terminals
  # below has stopped the processes and removed their directories. Deleting the
  # rows alone would strand an MT5 process on a worker node that nothing in this
  # system can see any more, holding memory forever.
  has_many :mt5_instances, dependent: :destroy
  # delete_all, not destroy: these are readonly audit records, like events.
  has_many :mt5_instance_events, dependent: :delete_all
  has_one :broker_credential, dependent: :destroy
  # delete_all, not destroy: events are readonly records, and instantiating
  # them to destroy would raise ActiveRecord::ReadOnlyRecord and break account
  # deletion entirely.
  has_many :events, dependent: :delete_all
  has_many :notifications, dependent: :delete_all
  has_many :push_subscriptions, dependent: :delete_all

  # The TOTP shared secret is a credential: encrypted at rest so a database
  # dump does not hand over the ability to generate valid codes.
  encrypts :otp_secret

  # Runs before any association is destroyed. Deleting an account is a legal
  # obligation, so this never blocks the deletion — but leaving a terminal
  # running would be worse than a slow delete, so it is attempted first and
  # reported loudly if it cannot be done.
  before_destroy :deprovision_terminals, prepend: true

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address,
            presence: true,
            uniqueness: { case_sensitive: false },
            format: { with: URI::MailTo::EMAIL_REGEXP, message: "must be a valid email address" }

  # NIST guidance favours length over composition rules. A long minimum with no
  # character-class requirements produces stronger passwords in practice than a
  # short one that forces a symbol.
  validates :password, length: { minimum: 12 }, allow_nil: true

  # Single-purpose, expiring tokens. Nothing is stored in the database: the
  # token is signed, so it cannot be forged, and it expires on its own.
  #
  # The password reset token is bound to password_salt, which means the token
  # is invalidated automatically the moment the password changes — a reset link
  # cannot be replayed after it has been used.
  generates_token_for :password_reset, expires_in: 15.minutes do
    password_salt&.last(10)
  end

  # Bound to the current email address, so a verification link stops working if
  # the address it was issued for is changed.
  generates_token_for :email_verification, expires_in: 2.days do
    email_address
  end

  # --------------------------------------------------------- Two-factor auth

  OTP_DRIFT_STEPS = 1          # accept one step either side, for clock skew
  OTP_INTERVAL = 30

  def otp_enabled? = otp_enabled_at.present?

  # Generated on enrolment but not trusted until a code is verified, so a user
  # cannot lock themselves out by walking away from the setup screen.
  def prepare_otp_secret!
    update!(otp_secret: ROTP::Base32.random, otp_enabled_at: nil, otp_last_used_step: nil)
    otp_secret
  end

  def otp_provisioning_uri
    return nil if otp_secret.blank?

    totp.provisioning_uri(email_address)
  end

  # Verifies a TOTP code and burns its time step.
  #
  # Returning the step from ROTP and refusing anything at or below the last one
  # used is what makes the code genuinely one-time: without it, a code stays
  # valid for the remainder of its window and can be replayed by anyone who
  # observed it.
  def verify_otp(code)
    return false if otp_secret.blank? || code.blank?

    timestamp = totp.verify(code.to_s.strip.delete(" "), drift_behind: OTP_INTERVAL, drift_ahead: OTP_INTERVAL)
    return false if timestamp.nil?

    step = timestamp.to_i / OTP_INTERVAL
    return false if otp_last_used_step.present? && step <= otp_last_used_step

    update!(otp_last_used_step: step)
    true
  end

  def enable_otp!
    update!(otp_enabled_at: Time.current)
  end

  def disable_otp!
    transaction do
      recovery_codes.delete_all
      update!(otp_secret: nil, otp_enabled_at: nil, otp_last_used_step: nil)
    end
  end

  # A second factor is satisfied by either an authenticator code or an unused
  # recovery code.
  def verify_second_factor(code)
    verify_otp(code) || RecoveryCode.consume(user: self, code:)
  end

  def totp
    ROTP::TOTP.new(otp_secret, issuer: Rails.application.config.x.product.name)
  end

  # ------------------------------------------------------------------------

  def notification_preferences_object = NotificationPreferences.new(self)

  def verified? = verified_at.present?

  def verify!
    update!(verified_at: Time.current) unless verified?
  end

  # Actions that can place orders or move money require a verified address.
  # Browsing and drafting configuration do not.
  def may_trade? = verified?

  private

  def deprovision_terminals
    mt5_instances.where.not(state: "terminated").find_each do |instance|
      result = Mt5::Deprovision.call(instance:, source: "web", reason: "account deleted")
      next if result.success?

      # The account still goes. An operator has to clean up by hand, so the
      # instance directory and node are named explicitly.
      Rails.logger.error(
        "mt5.orphaned_on_account_deletion #{instance.to_log.merge(error: result.error_code).to_json}"
      )
      Rails.error.report(StandardError.new("MT5 instance #{instance.uuid} outlived its account"),
                         handled: true, context: { instance: instance.uuid, node: instance.worker_node&.name })
    end
  end
end
