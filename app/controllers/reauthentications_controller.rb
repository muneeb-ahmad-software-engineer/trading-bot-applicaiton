# Password re-entry ("sudo mode") before a sensitive action.
#
# Guards actions that hand out credentials or weaken account security, so an
# unattended logged-in browser cannot be used to issue a trading-capable API
# token or disable two-factor authentication.
class ReauthenticationsController < ApplicationController
  rate_limit to: 10, within: 5.minutes, only: :create,
             with: -> { redirect_to dashboard_path, alert: "Too many attempts. Try again shortly." }

  def new
  end

  def create
    user = User.authenticate_by(email_address: current_user.email_address, password: params[:password].to_s)

    # When two-factor is on it must be satisfied here too, otherwise sudo mode
    # would be a password-only bypass of the second factor.
    if user && (!user.otp_enabled? || user.verify_second_factor(params[:code]))
      mark_recently_authenticated
      redirect_to session.delete(:return_to_after_reauthentication) || settings_path
    else
      flash.now[:alert] = "Incorrect password or code."
      render :new, status: :unprocessable_entity
    end
  end
end
