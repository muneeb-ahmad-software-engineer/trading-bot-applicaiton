module Notifications
  # Closes an open notification for a situation that has ended, so the same
  # alert can fire again if it recurs.
  class Resolve < ApplicationService
    def initialize(user:, dedup_key:)
      @user = user
      @dedup_key = dedup_key
    end

    def call
      notification = Notification.open_for(@user, @dedup_key)
      return success(nil) if notification.nil?

      notification.resolve!
      success(notification)
    end
  end
end
