class EmailVerificationsController < ApplicationController
  # The verification link is opened from an email client, so the visitor may not
  # carry a session cookie.
  allow_unauthenticated_access only: :show

  rate_limit to: 5, within: 10.minutes, only: :create,
             with: -> { redirect_to dashboard_path, alert: "Please wait before requesting another email." }

  def show
    user = User.find_by_token_for(:email_verification, params[:token])

    if user
      user.verify!
      Event.record("email.verified", user: user, ip_address: request.remote_ip)
      redirect_to dashboard_path, notice: "Your email address is verified."
    else
      redirect_to root_path, alert: "That verification link is invalid or has expired."
    end
  end

  def create
    if current_user.verified?
      redirect_to dashboard_path, notice: "Your email address is already verified."
    else
      EmailVerificationMailer.verify(current_user).deliver_later
      redirect_to dashboard_path, notice: "Verification email sent."
    end
  end
end
