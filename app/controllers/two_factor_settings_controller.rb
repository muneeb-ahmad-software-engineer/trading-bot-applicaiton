# Enrolling in and removing two-factor authentication.
class TwoFactorSettingsController < ApplicationController
  # Both enrolling and — especially — removing the second factor are sensitive.
  require_recent_authentication

  def new
    if current_user.otp_enabled?
      return redirect_to settings_path, notice: "Two-factor authentication is already on."
    end

    # A fresh secret each time the setup page is opened, so an abandoned
    # enrolment cannot be resumed later from a stale QR code.
    current_user.prepare_otp_secret!
    @provisioning_uri = current_user.otp_provisioning_uri
    @qr_code = qr_code_svg(@provisioning_uri)
  end

  def create
    # Enrolment is only confirmed by a working code. Turning it on without
    # proving the authenticator works would lock the user out of their account.
    if current_user.verify_otp(params[:code])
      current_user.enable_otp!
      Event.record("two_factor.enabled", user: current_user, ip_address: request.remote_ip)

      # Redirect rather than render: Turbo ignores a 200 HTML response to a form
      # POST, so rendering here would leave the user staring at the setup page
      # with no indication that two-factor had actually been switched on.
      #
      # The codes travel in the flash because they exist only in memory — they
      # are stored as digests and cannot be fetched again.
      redirect_to recovery_codes_path,
                  flash: { recovery_codes: RecoveryCode.regenerate_for(current_user),
                           notice: "Two-factor authentication is on." }
    else
      current_user.reload
      @provisioning_uri = current_user.otp_provisioning_uri
      @qr_code = qr_code_svg(@provisioning_uri)
      flash.now[:alert] = "That code is not valid. Check your authenticator and try again."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    current_user.disable_otp!
    Event.record("two_factor.disabled", user: current_user, ip_address: request.remote_ip)
    redirect_to settings_path, notice: "Two-factor authentication is off, and your recovery codes are void."
  end

  private

  def qr_code_svg(uri)
    RQRCode::QRCode.new(uri).as_svg(
      module_size: 4, standalone: true, use_path: true,
      color: "F1F5F9", fill: "0B1120"
    ).html_safe
  end
end
