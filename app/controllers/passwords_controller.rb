class PasswordsController < ApplicationController
  allow_unauthenticated_access
  before_action :set_user_by_token, only: %i[edit update]

  rate_limit to: 5, within: 10.minutes, only: :create,
             with: -> { redirect_to new_password_path, alert: "Too many requests. Try again shortly." }

  def new
  end

  def create
    user = User.find_by(email_address: params[:email_address].to_s.strip.downcase)
    PasswordsMailer.reset(user).deliver_later if user

    # The same response is returned whether or not the address exists, so this
    # form cannot be used to discover which addresses are registered.
    redirect_to login_path,
                notice: "If an account exists for that address, password reset instructions have been sent."
  end

  def edit
  end

  def update
    if @user.update(params.permit(:password, :password_confirmation))
      # Changing the password revokes every existing browser session and every
      # issued API token. If the account was compromised, the reset is what
      # actually evicts the attacker — including any MT5 or mobile client they
      # had connected.
      #
      # Except the tokens the platform issued to its own managed terminals.
      # Their plaintext exists only in the terminal's configuration on the
      # worker node — no browser or client ever sees it — so revoking one
      # evicts no attacker. It only cuts the user's running terminal off from
      # the platform, leaving open positions trading on stale configuration
      # and invisible to the dashboard.
      revocable = @user.api_tokens.active.where.missing(:mt5_instance)
      revoked = revocable.count
      @user.sessions.destroy_all
      revocable.find_each(&:revoke!)

      Event.record("password.changed", user: @user, ip_address: request.remote_ip,
                   metadata: { api_tokens_revoked: revoked })

      redirect_to login_path, notice: "Password reset. Please log in, and reconnect any API clients."
    else
      redirect_to edit_password_path(token: params[:token]),
                  alert: @user.errors.full_messages.to_sentence.presence || "Passwords did not match."
    end
  end

  private

  def set_user_by_token
    @user = User.find_by_password_reset_token!(params[:token])
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    redirect_to new_password_path, alert: "That password reset link is invalid or has expired."
  end
end
