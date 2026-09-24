module Authentication
  extend ActiveSupport::Concern

  # How long a browser session stays valid without re-authenticating. The Rails
  # generator issues a permanent (20 year) cookie; for a product that controls
  # trading, a bounded lifetime is the safer default.
  SESSION_DURATION = 30.days

  # How long a half-finished login (password accepted, second factor pending)
  # stays open before the user must start again.
  PENDING_AUTH_WINDOW = 10.minutes

  # How long a password re-entry keeps "sudo mode" open for sensitive actions.
  REAUTHENTICATION_WINDOW = 15.minutes

  included do
    before_action :require_authentication
    after_action :prevent_caching_of_account_pages
    helper_method :authenticated?, :current_user
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end

    # Gate actions that can place orders or move money behind a verified email
    # address. Browsing and drafting configuration deliberately do not require it.
    def require_verified_email(**options)
      before_action :require_verified_email, **options
    end

    # For actions that change security settings or hand out credentials. Being
    # logged in is not enough: an unattended browser must not be able to issue a
    # trading-capable API token or turn off two-factor authentication.
    def require_recent_authentication(**options)
      before_action :require_recent_authentication, **options
    end
  end

  private

  # A page rendered for a signed-in account carries balances, positions, an
  # email address and IP history. Rails' default of "private, must-revalidate"
  # still permits a cache to store it — including the service worker, and the
  # browser's back-forward cache after logout. no-store is the only directive
  # that actually forbids keeping a copy.
  def prevent_caching_of_account_pages
    return unless Current.session

    response.headers["Cache-Control"] = "no-store"
    response.headers["Pragma"] = "no-cache"
  end

  def authenticated?
    resume_session.present?
  end

  def current_user
    Current.session&.user
  end

  def require_authentication
    resume_session || request_authentication
  end

  def resume_session
    Current.session ||= find_session_by_cookie
  end

  def find_session_by_cookie
    return nil unless (id = cookies.signed[:session_id])

    Session.find_by(id:)
  end

  def request_authentication
    # HEAD is routed like GET, and request.get? is false for it — check both so
    # the return-to path cannot depend on which of the two verbs was used.
    session[:return_to_after_authenticating] = request.url if request.get? || request.head?
    redirect_to login_path, alert: "Please log in to continue."
  end

  def require_verified_email
    return if current_user&.verified?

    redirect_to dashboard_path,
                alert: "Please verify your email address before using this feature."
  end

  # ------------------------------------------------- Two-factor challenge
  #
  # When a password is accepted but a second factor is still outstanding, no
  # Session record is created and no session cookie is issued. The half-finished
  # login lives only in the encrypted cookie session. An attacker holding just
  # the password therefore never obtains an authenticated session.

  def start_two_factor_challenge(user)
    reset_session
    session[:pending_authentication_user_id] = user.id
    session[:pending_authentication_at] = Time.current.to_i
  end

  def pending_authentication_user
    id = session[:pending_authentication_user_id]
    started = session[:pending_authentication_at]
    return nil if id.blank? || started.blank?

    if Time.zone.at(started.to_i) < PENDING_AUTH_WINDOW.ago
      clear_pending_authentication
      return nil
    end

    User.find_by(id:)
  end

  def clear_pending_authentication
    session.delete(:pending_authentication_user_id)
    session.delete(:pending_authentication_at)
  end

  # ------------------------------------------------------------ Sudo mode

  def mark_recently_authenticated
    session[:reauthenticated_at] = Time.current.to_i
  end

  def recently_authenticated?
    at = session[:reauthenticated_at]
    at.present? && Time.zone.at(at.to_i) > REAUTHENTICATION_WINDOW.ago
  end

  def require_recent_authentication
    return if recently_authenticated?

    session[:return_to_after_reauthentication] = request.get? || request.head? ? request.url : request.referer
    redirect_to new_reauthentication_path, alert: "Confirm your password to continue."
  end

  def after_authentication_url
    session.delete(:return_to_after_authenticating) || dashboard_url
  end

  def start_new_session_for(user)
    user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |new_session|
      Current.session = new_session

      clear_pending_authentication
      mark_recently_authenticated

      Event.record("session.started", user: user, subject: new_session,
                   ip_address: request.remote_ip,
                   metadata: { user_agent: request.user_agent, two_factor: user.otp_enabled? })

      cookies.signed[:session_id] = {
        value: new_session.id,
        expires: SESSION_DURATION.from_now,
        httponly: true,                    # not readable by JavaScript
        secure: Rails.env.production?,     # HTTPS only once deployed
        same_site: :lax                    # blocks cross-site POST, keeps normal navigation
      }
    end
  end

  def terminate_session
    Current.session&.destroy
    Current.session = nil
    cookies.delete(:session_id)
  end
end
