class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[new create]

  # Throttles credential stuffing against a single address. Rails 8 provides
  # this natively, backed by Solid Cache, so no gem is required.
  rate_limit to: 10, within: 3.minutes, only: :create,
             with: -> { redirect_to login_path, alert: "Too many attempts. Try again in a few minutes." }

  def new
  end

  def create
    user = User.authenticate_by(params.permit(:email_address, :password).to_h.symbolize_keys)

    if user.nil?
      # Deliberately does not distinguish an unknown address from a wrong
      # password: doing so would let an attacker enumerate registered users.
      return redirect_to login_path, alert: "Incorrect email address or password."
    end

    if user.otp_enabled?
      # No Session record and no session cookie yet — the login is only half
      # finished. See Authentication#start_two_factor_challenge.
      start_two_factor_challenge(user)
      redirect_to new_two_factor_challenge_path
    else
      start_new_session_for(user)
      redirect_to after_authentication_url, notice: "Signed in."
    end
  end

  def destroy
    terminate_session
    redirect_to root_path, notice: "Signed out."
  end
end
