module Api
  module V1
    # Base class for every /api/v1 endpoint.
    #
    # API requests are stateless and bearer-token authenticated. They never
    # carry a session cookie, so CSRF protection — a cookie-session concern —
    # does not apply, and ActionController::API does not include it.
    #
    # This is the seam the MT5 Expert Advisor and the future mobile
    # applications talk to.
    class BaseController < ActionController::API
      include ApiAuthentication

      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      rescue_from ActionController::ParameterMissing, with: :bad_request

      private

      def not_found
        render_error("not_found", "Resource not found", :not_found)
      end

      def bad_request(exception)
        render_error("bad_request", exception.message, :bad_request)
      end

      def render_error(code, message, status)
        render json: { error: { code:, message: } }, status:
      end
    end
  end
end
