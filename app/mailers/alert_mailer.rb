class AlertMailer < ApplicationMailer
  def alert(notification)
    @notification = notification
    @user = notification.user
    @url = full_url(notification.url)

    subject = "#{notification.severity == 'critical' ? '[Action needed] ' : ''}#{notification.title}"

    mail to: @user.email_address, subject:
  end

  private

  def full_url(path)
    return root_url if path.blank?

    URI.join(root_url, path).to_s
  end
end
