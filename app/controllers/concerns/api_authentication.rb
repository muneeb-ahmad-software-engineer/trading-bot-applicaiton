# Bearer-token authentication for /api/v1.
#
# Used by the MT5 Expert Advisor and by native mobile applications. Kept
# entirely separate from the browser session flow: API clients never receive or
# send a session cookie, so there is no CSRF surface here to defend.
module ApiAuthentication
  extend ActiveSupport::Concern

  included do
    before_action :require_api_authentication
  end

  class_methods do
    def allow_unauthenticated_api_access(**options)
      skip_before_action :require_api_authentication, **options
    end

    def require_verified_email(**options)
      before_action :require_verified_email_for_api, **options
    end
  end

  private

  def current_api_token = @current_api_token

  def current_user = @current_api_token&.user

  def require_api_authentication
    token = ApiToken.authenticate(bearer_token)

    return unauthorized unless token

    @current_api_token = token
    token.touch_last_used!
  end

  def require_verified_email_for_api
    return if current_user&.verified?

    render json: {
      error: {
        code: "email_unverified",
        message: "Verify your email address before using this endpoint."
      }
    }, status: :forbidden
  end

  # Reads a token from `Authorization: Bearer <token>`.
  def bearer_token
    pattern = /\ABearer\s+/
    header = request.headers["Authorization"]

    header.sub(pattern, "") if header&.match?(pattern)
  end

  def unauthorized
    # The WWW-Authenticate header tells a well-behaved client what scheme to use.
    response.set_header("WWW-Authenticate", 'Bearer realm="api"')

    render json: {
      error: { code: "unauthorized", message: "Invalid or missing API token." }
    }, status: :unauthorized
  end
end
