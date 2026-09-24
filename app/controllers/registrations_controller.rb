class RegistrationsController < ApplicationController
  allow_unauthenticated_access only: %i[new create]

  rate_limit to: 5, within: 10.minutes, only: :create,
             with: -> { redirect_to signup_path, alert: "Too many sign-up attempts. Try again shortly." }

  def new
    @user = User.new
  end

  def create
    @user = User.new(registration_params)

    if @user.save
      EmailVerificationMailer.verify(@user).deliver_later
      start_new_session_for(@user)
      redirect_to dashboard_path,
                  notice: "Welcome. Check your email to verify your address."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def registration_params
    params.expect(user: %i[email_address password password_confirmation])
  end
end
