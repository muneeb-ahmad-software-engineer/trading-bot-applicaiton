# Notification preferences and push device registration.
class NotificationSettingsController < ApplicationController
  def show
    @preferences = current_user.notification_preferences_object
    @devices = current_user.push_subscriptions.order(created_at: :desc)
  end

  def update
    current_user.notification_preferences_object.update(preference_params)

    redirect_to notification_settings_path, notice: "Notification preferences saved."
  end

  private

  def preference_params
    params.fetch(:preferences, {}).permit(
      AlertType.keys.index_with { AlertType::CHANNELS }
    ).to_h
  end
end
