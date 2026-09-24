# Wrapper around the JSONB preferences document on User.
#
# Kept as a value object rather than a table: it is a settings blob, read whole,
# and never queried across users.
class NotificationPreferences
  def initialize(user)
    @user = user
  end

  # Mandatory alert types are always on, whatever the stored document says.
  # Storing "off" for them would be a lie the user could later rely on.
  def enabled?(alert_type, channel)
    return false unless AlertType.exists?(alert_type)
    return false unless AlertType::CHANNELS.include?(channel.to_s)
    return true if AlertType.mandatory?(alert_type)

    stored.dig(alert_type.to_s, channel.to_s) != false
  end

  def channels_for(alert_type)
    AlertType::CHANNELS.select { |channel| enabled?(alert_type, channel) }
  end

  def update(submitted)
    document = {}

    AlertType.keys.each do |type|
      next if AlertType.mandatory?(type)

      document[type] = AlertType::CHANNELS.index_with do |channel|
        submitted.dig(type, channel).to_s == "1"
      end
    end

    @user.update!(notification_preferences: document)
  end

  def to_h = stored

  private

  def stored = @user.notification_preferences.presence || {}
end
