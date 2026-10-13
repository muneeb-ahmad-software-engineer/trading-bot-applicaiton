# The broker account a user's managed MT5 terminal signs in to.
#
# This is the most sensitive thing the application stores: the login and
# password it holds can place trades and, at some brokers, request a
# withdrawal. Saving one therefore requires a verified email address and a
# recent password entry, on the same reasoning as issuing an API token.
#
# Removing one does not, and deliberately so. A user who believes their
# credentials are compromised must be able to pull them out of the platform
# immediately, not after finding their password.
class BrokerCredentialsController < ApplicationController
  require_verified_email only: :update
  require_recent_authentication only: :update

  before_action :set_credential

  def edit
    @instance = current_user.mt5_instances.not_terminated.first
  end

  def update
    # The password field is left blank to keep the existing one. Without this a
    # user correcting a typo in their server name would have to retype a broker
    # password the form cannot show them.
    attributes = credential_params
    attributes.delete(:password) if attributes[:password].blank? && @credential.persisted?

    if @credential.update(attributes)
      Event.record("broker_credential.saved", user: current_user, subject: @credential,
                   ip_address: request.remote_ip, metadata: @credential.to_log)

      redirect_to edit_broker_credential_path, notice: notice_for_save
    else
      @instance = current_user.mt5_instances.not_terminated.first
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    return redirect_to(edit_broker_credential_path, alert: "There are no broker details to remove.") unless @credential.persisted?

    # The terminal exists only to sign in with these credentials. Leaving it
    # running against a broker account the user has just disowned is not an
    # option, so it goes first — and its directory with it, because that
    # directory holds a copy of the very password being removed.
    remove_terminal

    @credential.destroy

    Event.record("broker_credential.removed", user: current_user,
                 ip_address: request.remote_ip, metadata: { server: @credential.server })

    redirect_to edit_broker_credential_path,
                notice: "Broker details removed and your terminal shut down. Running strategies will not place new orders."
  end

  private

  def set_credential
    @credential = current_user.broker_credential || current_user.build_broker_credential
  end

  # Replaces the generic guard for this page. The form cannot be held across a
  # password confirmation, so without saying so the user returns to an empty
  # form and reasonably believes the save went through.
  def require_recent_authentication
    return if recently_authenticated?

    session[:return_to_after_reauthentication] = edit_broker_credential_path
    redirect_to new_reauthentication_path,
                alert: "Confirm your password first. Your broker details were not saved, so enter them again after confirming."
  end

  def notice_for_save
    if current_user.strategies.running.any?
      "Broker details saved. Restart your strategy to reconnect the terminal with them."
    else
      "Broker details saved. Start a strategy and your terminal will sign in with them."
    end
  end

  def remove_terminal
    instance = current_user.mt5_instances.not_terminated.first
    return if instance.nil?

    result = Mt5::Deprovision.call(instance:, actor: current_user, source: "web",
                                   reason: "broker credentials removed")

    # Reported, never raised. A terminal that refuses to die must not be able to
    # keep a user's broker password in this database.
    return if result.success?

    Rails.logger.error("broker_credential.terminal_not_removed #{instance.to_log.merge(error: result.error_code).to_json}")
  end

  def credential_params
    params.expect(broker_credential: %i[server login password demo])
  end
end
