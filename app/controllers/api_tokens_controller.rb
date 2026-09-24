# API tokens the user issues for their MT5 terminal or a mobile device.
class ApiTokensController < ApplicationController
  # Issuing a token is a trading-capable action, so it requires a verified
  # email address. Viewing and revoking existing tokens deliberately do not —
  # a user must always be able to revoke access.
  require_verified_email only: %i[create regenerate]

  # An API token can trade. Handing one out requires the user to have proved
  # themselves recently, not merely to have an open session.
  require_recent_authentication only: %i[create regenerate]

  def index
    @api_tokens = current_user.api_tokens.order(created_at: :desc)
  end

  def create
    token = ApiToken.issue(user: current_user, name: token_params[:name].presence || "API client")

    # The plaintext token is shown exactly once. It is placed in the flash
    # rather than persisted, because it cannot be recovered later by design.
    Event.record("api_token.issued", user: current_user, subject: token,
                 ip_address: request.remote_ip, metadata: { name: token.name })

    redirect_to api_tokens_path, flash: {
      new_token: token.plaintext_token,
      notice: "Token created. Copy it now — it will not be shown again."
    }
  rescue ActiveRecord::RecordInvalid => e
    redirect_to api_tokens_path, alert: e.record.errors.full_messages.to_sentence
  end

  # Rotation: the old token stops working and a replacement is issued under the
  # same name. Done as one action rather than leaving the user to revoke and
  # re-create, because the gap between those two steps is downtime for whatever
  # client was using it.
  #
  # The old record is kept (revoked, not deleted) so the audit trail still
  # explains what the terminal was authenticating with yesterday.
  def regenerate
    previous = current_user.api_tokens.find(params[:id])

    token = ApiToken.transaction do
      previous.revoke! if previous.active?
      ApiToken.issue(user: current_user, name: previous.name)
    end

    Event.record("api_token.regenerated", user: current_user, subject: token,
                 ip_address: request.remote_ip,
                 metadata: { name: token.name, replaced_token_id: previous.id })

    redirect_to api_tokens_path, flash: {
      new_token: token.plaintext_token,
      notice: "Token regenerated. Copy it now — it will not be shown again."
    }
  rescue ActiveRecord::RecordInvalid => e
    redirect_to api_tokens_path, alert: e.record.errors.full_messages.to_sentence
  end

  def destroy
    # Scoped through current_user, so one account cannot revoke another's token.
    token = current_user.api_tokens.find(params[:id])
    token.revoke!

    Event.record("api_token.revoked", user: current_user, subject: token,
                 ip_address: request.remote_ip, metadata: { name: token.name })

    redirect_to api_tokens_path, notice: "Token revoked. Any client using it is now disconnected."
  end

  # Removes the record entirely, for tidying up a long list. Revoking is what
  # actually cuts off access, so deletion is only offered afterwards: it must
  # never be the action a user reaches for in a hurry to shut a client out.
  #
  # The api_token.issued and api_token.revoked events survive this — they carry
  # the name in their metadata and are not foreign-keyed to the token.
  def purge
    token = current_user.api_tokens.find(params[:id])

    if token.active?
      return redirect_to api_tokens_path,
                         alert: "Revoke #{token.name} before deleting it, so its client is disconnected first."
    end

    # A terminal record points at the token it was provisioned with. Deleting
    # the token nullifies that link, which would leave a running MT5 process
    # with nothing to trace it back to.
    if token.mt5_instance.present? && !token.mt5_instance.terminated?
      return redirect_to api_tokens_path,
                         alert: "#{token.name} is still attached to a terminal. It can be deleted once that terminal has stopped."
    end

    name = token.name
    token.destroy!

    Event.record("api_token.deleted", user: current_user, ip_address: request.remote_ip,
                 metadata: { name: name })

    redirect_to api_tokens_path, notice: "#{name} deleted."
  end

  private

  def token_params
    params.fetch(:api_token, {}).permit(:name)
  end
end
