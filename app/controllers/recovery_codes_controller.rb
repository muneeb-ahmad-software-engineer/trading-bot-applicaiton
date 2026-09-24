# Backup codes for when a user loses their authenticator device.
class RecoveryCodesController < ApplicationController
  require_recent_authentication

  # Renders codes handed over in the flash by the action that generated them.
  # There is nothing to show on a direct visit: the codes are stored as digests
  # and cannot be recovered.
  def show
    @codes = flash[:recovery_codes]

    redirect_to settings_path if @codes.blank?
  end

  def create
    return redirect_to settings_path, alert: "Turn on two-factor authentication first." unless current_user.otp_enabled?

    # Regenerating invalidates every previous code, which is the point: it is
    # what a user does when they think an old set has been exposed.
    Event.record("recovery_codes.regenerated", user: current_user, ip_address: request.remote_ip)

    redirect_to recovery_codes_path,
                flash: { recovery_codes: RecoveryCode.regenerate_for(current_user),
                         notice: "New recovery codes generated. Your previous codes no longer work." }
  end
end
