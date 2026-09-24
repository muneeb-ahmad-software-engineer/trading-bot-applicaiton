# Registers a browser to receive push notifications.
class PushSubscriptionsController < ApplicationController
  def create
    PushSubscription.subscribe(
      user: current_user,
      endpoint: subscription_params[:endpoint],
      p256dh_key: subscription_params[:p256dh_key],
      auth_key: subscription_params[:auth_key],
      user_agent: request.user_agent
    )

    head :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def destroy
    # Scoped through current_user so one account cannot unsubscribe another's device.
    current_user.push_subscriptions.find(params[:id]).destroy

    redirect_to notification_settings_path, notice: "Device removed."
  end

  private

  def subscription_params
    params.permit(:endpoint, :p256dh_key, :auth_key)
  end
end
