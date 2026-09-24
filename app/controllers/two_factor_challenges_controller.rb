# The second step of logging in, for accounts with two-factor enabled.
class TwoFactorChallengesController < ApplicationController
  allow_unauthenticated_access

  before_action :set_pending_user

  # Six digits is a small search space, so the throttle is what makes brute
  # force impractical. Keyed per IP by default.
  rate_limit to: 10, within: 5.minutes, only: :create,
             with: -> { redirect_to login_path, alert: "Too many attempts. Please log in again." }

  def new
  end

  def create
    if @user.verify_second_factor(params[:code])
      start_new_session_for(@user)
      redirect_to after_authentication_url, notice: "Signed in."
    else
      flash.now[:alert] = "That code is not valid. Codes expire after 30 seconds."
      render :new, status: :unprocessable_entity
    end
  end

  private

  def set_pending_user
    @user = pending_authentication_user

    # No pending login, or it expired: send the user back to the start rather
    # than leaving a challenge form that can never succeed.
    redirect_to login_path, alert: "Please log in again." if @user.nil?
  end
end
