class SettingsController < ApplicationController
  def show
    @sessions = current_user.sessions.order(created_at: :desc)
  end
end
