class EmailVerificationMailer < ApplicationMailer
  def verify(user)
    @user = user
    @url = verify_email_url(token: user.generate_token_for(:email_verification))

    mail to: user.email_address, subject: "Verify your email address"
  end
end
